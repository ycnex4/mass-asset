// Finalization transaction of the Mass Asset release (scripts/finalize.sh): BPF upgradeable loader
// SetAuthority with no new authority, on the ProgramData account, signed by the current authority.
//
//   node finalize-tx.mjs send   <rpc> <wallet keypair file> <program id> <record.json> <intent sha256>
//   node finalize-tx.mjs verify <rpc> <record.json>
//
// send: builds and signs the transaction, writes its signature, blockhash and last valid block height to
//       <record.json> BEFORE sending (the record is never overwritten), sends once, then runs verify.
// verify: reads the result from the network only — it never signs or sends. Exit codes:
//   0  finalized, meta.err null, and the transaction is exactly SetAuthority(None) for this ProgramData
//      signed by the recorded authority;
//   3  not executed, definitively: not found and the blockhash has expired (safe to start over);
//   4  undetermined yet (not finalized / not found before expiry): run verify again later;
//   5  not the expected transaction (instruction, accounts, signature, blockhash) or inconsistent record;
//   7  the expected instruction executed and FAILED (finalized with an error; nothing changed on chain);
//   6  the ProgramData authority is already none at finalized, but this transaction cannot be retrieved
//      (e.g. the RPC keeps no transaction history): the program is final, the signature unconfirmed.
// "Not executed" (3) means: the blockhash has expired at finalized AND the ProgramData at finalized still
// has the recorded authority. It prints expired_check_slot=<finalized slot>; finalize.sh then requires a
// full finalized snapshot (same ProgramData, slot, authority, bytecode) from a context at or after that
// slot before it allows a new attempt. RPC errors are retried, never read as "not found".
// The keypair file is read, never printed.
import fs from "node:fs";
import path from "node:path";
import { Connection, Keypair, PublicKey, Transaction, TransactionInstruction } from "@solana/web3.js";

const LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
const SET_AUTHORITY = Buffer.from([4, 0, 0, 0]); // UpgradeableLoaderInstruction::SetAuthority
const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function base58(bytes) {
  let n = BigInt("0x" + (Buffer.from(bytes).toString("hex") || "0"));
  let out = "";
  while (n > 0n) { out = ALPHABET[Number(n % 58n)] + out; n /= 58n; }
  for (const b of bytes) { if (b !== 0) break; out = "1" + out; }
  return out;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const [, , mode, rpc, ...rest] = process.argv;
const connection = new Connection(rpc, "finalized");

// Authority of the ProgramData at finalized, read from a context at or after <minSlot>:
// a pubkey, "none", or null if unreadable / the context is older.
async function programDataAuthority(address, minSlot) {
  const { context, value: info } = await connection.getAccountInfoAndContext(new PublicKey(address), "finalized");
  if (context.slot < minSlot) return null;
  if (!info || !info.owner.equals(LOADER) || info.data.length < 45 || info.data.readUInt32LE(0) !== 3) return null;
  if (info.data[12] === 0) return "none";
  if (info.data[12] === 1) return new PublicKey(info.data.subarray(13, 45)).toBase58();
  return null;
}

async function verify(recPath) {
  const rec = JSON.parse(fs.readFileSync(recPath, "utf8"));
  try {
    const [derived] = PublicKey.findProgramAddressSync([new PublicKey(rec.program).toBuffer()], LOADER);
    if (derived.toBase58() !== rec.programdata) throw new Error(`programdata ${rec.programdata} is not the ProgramData of ${rec.program}`);
    new PublicKey(rec.authority);
  } catch (e) {
    console.log(`FINALIZE_TX BAD RECORD: ${e?.message ?? e}`);
    process.exit(2);
  }
  if (typeof rec.signature !== "string" || !/^[1-9A-HJ-NP-Za-km-z]{64,88}$/.test(rec.signature)) {
    console.log(`FINALIZE_TX BAD RECORD: signature ${JSON.stringify(rec.signature)} is not a base58 signature`);
    process.exit(2);
  }
  const deadline = Date.now() + 180_000;
  let lastError = "";
  while (Date.now() < deadline) {
    try {
    const st = (await connection.getSignatureStatuses([rec.signature], { searchTransactionHistory: true })).value[0];
    if (st && st.confirmationStatus === "finalized") {
      const tx = await connection.getTransaction(rec.signature, { commitment: "finalized", maxSupportedTransactionVersion: 0 });
      if (!tx || !tx.meta) { await sleep(3000); continue; } // no meta: not a usable result yet
      const msg = tx.transaction.message;
      const keys = msg.staticAccountKeys.map((k) => k.toBase58());
      const ixs = msg.compiledInstructions;
      const problems = [];
      if (tx.transaction.signatures[0] !== rec.signature) problems.push(`response signature ${tx.transaction.signatures[0]}`);
      if (msg.recentBlockhash !== rec.blockhash) problems.push(`blockhash ${msg.recentBlockhash} != recorded ${rec.blockhash}`);
      if (ixs.length !== 1) problems.push(`${ixs.length} instructions`);
      const ix = ixs[0];
      if (ix) {
        if (keys[ix.programIdIndex] !== LOADER.toBase58()) problems.push(`program ${keys[ix.programIdIndex]}`);
        if (!Buffer.from(ix.data).equals(SET_AUTHORITY)) problems.push(`data ${Buffer.from(ix.data).toString("hex")}`);
        const accs = ix.accountKeyIndexes.map((i) => keys[i]);
        if (accs.length !== 2 || accs[0] !== rec.programdata || accs[1] !== rec.authority) problems.push(`accounts ${accs.join(",")}`);
      }
      if (keys[0] !== rec.authority) problems.push(`fee payer ${keys[0]}`);
      if (tx.meta.err === undefined) problems.push("meta.err missing");
      if (problems.length) {
        console.log(`FINALIZE_TX UNEXPECTED signature=${rec.signature} slot=${tx.slot}: ${problems.join("; ")}`);
        process.exit(5);
      }
      if (tx.meta.err !== null && tx.meta.err !== undefined) {
        console.log(`FINALIZE_TX EXECUTED WITH ERROR signature=${rec.signature} slot=${tx.slot} err=${JSON.stringify(tx.meta?.err)}`);
        process.exit(7);
      }
      console.log(`FINALIZE_TX OK signature=${rec.signature} slot=${tx.slot} status=finalized err=null instruction=SetAuthority(None) programdata=${rec.programdata} authority=${rec.authority}`);
      process.exit(0);
    }
    if (!st) {
      // Slot and block height of ONE finalized block establish the expiry.
      const checkSlot = await connection.getSlot("finalized");
      const block = await connection.getBlock(checkSlot, { commitment: "finalized", transactionDetails: "none", rewards: false, maxSupportedTransactionVersion: 0 });
      const height = block?.blockHeight;
      if (typeof height === "number" && height > rec.lastValidBlockHeight) {
        const auth = await programDataAuthority(rec.programdata, checkSlot);
        if (auth === rec.authority) {
          console.log(`FINALIZE_TX NOT EXECUTED signature=${rec.signature}: not found, blockhash expired (finalized block slot ${checkSlot} height ${height} > ${rec.lastValidBlockHeight}) and ProgramData authority at finalized (context ≥ ${checkSlot}) is still ${auth}; expired_check_slot=${checkSlot}`);
          process.exit(3);
        }
        if (auth === "none") {
          console.log(`FINALIZE_TX STATE FINAL, TRANSACTION NOT RETRIEVABLE signature=${rec.signature}: ProgramData authority is none at finalized, but the transaction is not found (no history on this RPC?)`);
          process.exit(6);
        }
        console.log(`FINALIZE_TX UNDETERMINED signature=${rec.signature}: not found, blockhash expired, ProgramData authority at finalized is ${auth ?? "unreadable"}, not ${rec.authority}`);
        process.exit(4);
      }
    }
    } catch (e) {
      const msg = `${e?.message ?? e}`;
      if (msg !== lastError) console.log(`  RPC error (retrying, not treated as "not found"): ${msg}`);
      lastError = msg;
    }
    await sleep(3000);
  }
  console.log(`FINALIZE_TX UNDETERMINED signature=${rec.signature}: not finalized yet${lastError ? ` (last RPC error: ${lastError})` : ""}; run verify again`);
  process.exit(4);
}

if (mode === "send") {
  const [walletPath, idArg, recPath, intentSha] = rest;
  if (!/^[0-9a-f]{64}$/.test(intentSha ?? "")) { console.error("send needs the intent sha256"); process.exit(2); }
  if (fs.existsSync(recPath)) { console.error(`refusing to overwrite ${recPath}: verify it instead`); process.exit(2); }
  const wallet = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(fs.readFileSync(walletPath, "utf8"))));
  const programId = new PublicKey(idArg);
  const [programData] = PublicKey.findProgramAddressSync([programId.toBuffer()], LOADER);
  const ix = new TransactionInstruction({
    programId: LOADER,
    keys: [
      { pubkey: programData, isSigner: false, isWritable: true },
      { pubkey: wallet.publicKey, isSigner: true, isWritable: false },
    ],
    data: SET_AUTHORITY,
  });
  const latest = await connection.getLatestBlockhash("finalized");
  const tx = new Transaction({ feePayer: wallet.publicKey, recentBlockhash: latest.blockhash }).add(ix);
  tx.sign(wallet);
  const signature = base58(tx.signature);
  const rec = { signature, blockhash: latest.blockhash, lastValidBlockHeight: latest.lastValidBlockHeight,
    programdata: programData.toBase58(), authority: wallet.publicKey.toBase58(), program: programId.toBase58(),
    intent_sha256: intentSha,
    created_at_utc: new Date().toISOString() };
  // The record must be complete and durable BEFORE the transaction is sent: exclusive create, a write loop
  // until every byte is written (write(2) may write fewer), fsync of the file, of its directory and of that
  // directory's parent (the attempt directory is new), then a read-back that must equal what was written.
  const text = Buffer.from(JSON.stringify(rec, null, 2) + "\n", "utf8");
  const fd = fs.openSync(recPath, "wx", 0o600);
  try {
    for (let off = 0; off < text.length;) {
      const n = fs.writeSync(fd, text, off, text.length - off);
      if (!(n > 0)) throw new Error(`short write of ${recPath} (${off} of ${text.length} bytes)`);
      off += n;
    }
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  for (const dir of [path.dirname(recPath), path.dirname(path.dirname(recPath))]) {
    const dfd = fs.openSync(dir, "r"); try { fs.fsyncSync(dfd); } finally { fs.closeSync(dfd); }
  }
  if (!fs.readFileSync(recPath).equals(text)) throw new Error(`${recPath} does not read back as written; not sending`);
  console.log(`FINALIZE_TX SIGNED signature=${signature} (recorded in ${recPath} before sending)`);
  try {
    await connection.sendRawTransaction(tx.serialize(), { skipPreflight: false, preflightCommitment: "finalized", maxRetries: 10 });
  } catch (e) {
    console.log(`FINALIZE_TX send reported: ${e?.message ?? e} — reading the result from the network`);
  }
  await verify(recPath);
} else if (mode === "verify") {
  await verify(rest[0]);
} else {
  console.error("usage: node finalize-tx.mjs send <rpc> <wallet> <program id> <record.json> | verify <rpc> <record.json>");
  process.exit(2);
}
