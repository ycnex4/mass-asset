// Consistent finalized snapshot of an upgradeable program: the Program account and its ProgramData
// account come from ONE getMultipleAccounts response at commitment "finalized", and the bytecode is
// taken from that same response (release scripts: scripts/common.sh, snapshot()).
//
//   node snapshot.mjs <rpc> <program id> <elf output path>
//
// Prints:  state: programdata=<address> slot=<last deployment slot> authority=<pubkey|none>
//          context_slot: <slot of the response>
// and writes the bytecode (ProgramData data after its 45-byte header, as `solana program dump` does)
// to <elf output path>. Exit 1 if the accounts are missing or not an upgradeable program.
import fs from "node:fs";
import { Connection, PublicKey } from "@solana/web3.js";

const LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
const PROGRAMDATA_HEADER = 45; // u32 tag 3, u64 slot, Option<Pubkey> (1 + 32)

const [, , rpc, idArg, elfOut] = process.argv;
if (!rpc || !idArg || !elfOut) {
  console.error("usage: node snapshot.mjs <rpc> <program id> <elf output path>");
  process.exit(2);
}
const fail = (msg) => { console.error(`snapshot: ${msg}`); process.exit(1); };

const programId = new PublicKey(idArg);
const [programData] = PublicKey.findProgramAddressSync([programId.toBuffer()], LOADER);
const connection = new Connection(rpc, "finalized");
const { context, value } = await connection.getMultipleAccountsInfoAndContext([programId, programData], "finalized");
const [prog, pd] = value;

if (!prog) fail(`program account ${programId.toBase58()} not found at finalized`);
if (!prog.owner.equals(LOADER)) fail(`program account owner ${prog.owner.toBase58()} is not the upgradeable loader`);
if (prog.data.length < 36 || prog.data.readUInt32LE(0) !== 2) fail("program account is not UpgradeableLoaderState::Program");
if (!new PublicKey(prog.data.subarray(4, 36)).equals(programData)) fail("program account points to another ProgramData");
if (!pd) fail(`ProgramData ${programData.toBase58()} not found at finalized (closed program?)`);
if (!pd.owner.equals(LOADER)) fail("ProgramData owner is not the upgradeable loader");
if (pd.data.length < PROGRAMDATA_HEADER || pd.data.readUInt32LE(0) !== 3) fail("ProgramData is not UpgradeableLoaderState::ProgramData");

const slot = pd.data.readBigUInt64LE(4);
const tag = pd.data[12];
let authority;
if (tag === 0) authority = "none";
else if (tag === 1) authority = new PublicKey(pd.data.subarray(13, 45)).toBase58();
else fail(`ProgramData authority option tag ${tag}`);

fs.writeFileSync(elfOut, pd.data.subarray(PROGRAMDATA_HEADER));
console.log(`state: programdata=${programData.toBase58()} slot=${slot} authority=${authority}`);
console.log(`context_slot: ${context.slot}`);
