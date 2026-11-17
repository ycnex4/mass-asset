//! Mass Asset v1 (format 2) — minimal on-chain asset for X1.
//!
//! Normative specification: `docs/spec/v1-format2-draft.md` (format 2).
//!
//! Account layout (little-endian), HEADER_LEN = 104:
//!   [0]        version         u8  = 2
//!   [1]        flags           u8  bits 0-1 transfer_mode, bits 2-7 must be 0
//!   [2..4]     payload_len     u16 (<= 1024)
//!   [4..36]    namespace       Pubkey (issuing program)
//!   [36..68]   owner           Pubkey
//!   [68..100]  delegate        Pubkey (all zeros = none)
//!   [100]      authority_bump  u8  canonical bump of PDA(["mass-asset-authority"], namespace)
//!   [101..104] reserved        must be 0
//!   [104..]    payload         [u8; payload_len] (8-byte aligned)
//!
//! Every successful instruction emits exactly one `sol_log_data` event (spec §7).
//! Error logs are static strings only (no formatting) to keep the binary small and CU low.

use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    instruction::{AccountMeta, Instruction},
    log::sol_log_data,
    msg,
    program::{invoke, invoke_signed},
    program_error::ProgramError,
    pubkey::Pubkey,
    rent::Rent,
    sysvar::Sysvar,
};

entrypoint!(process_instruction);

// ---------------------------------------------------------------------------
// Constants (spec §0.2)
// ---------------------------------------------------------------------------

pub const VERSION: u8 = 2;
pub const OBJECT_SEED: &[u8] = b"ma1-asset";
pub const AUTHORITY_SEED: &[u8] = b"mass-asset-authority";
pub const HEADER_LEN: usize = 104;
pub const MAX_PAYLOAD: usize = 1024;

pub const OFF_VERSION: usize = 0;
pub const OFF_FLAGS: usize = 1;
pub const OFF_PAYLOAD_LEN: usize = 2;
pub const OFF_NAMESPACE: usize = 4;
pub const OFF_OWNER: usize = 36;
pub const OFF_DELEGATE: usize = 68;
pub const OFF_AUTHORITY_BUMP: usize = 100;
pub const OFF_RESERVED: usize = 101;

const TRANSFER_MODE_MASK: u8 = 0b0000_0011;
const RESERVED_FLAGS_MASK: u8 = 0b1111_1100;

pub const MODE_OWNER: u8 = 0;
pub const MODE_NAMESPACE: u8 = 1;
pub const MODE_FROZEN: u8 = 2;

/// System program id (11111111111111111111111111111111).
pub const SYSTEM_PROGRAM_ID: Pubkey = Pubkey::new_from_array([0u8; 32]);

/// BPFLoaderUpgradeab1e11111111111111111111111
pub const BPF_LOADER_UPGRADEABLE: Pubkey = Pubkey::new_from_array([
    2, 168, 246, 145, 78, 136, 161, 176, 226, 16, 21, 62, 247, 99, 174, 43, 0, 194, 185, 61, 22,
    193, 36, 210, 192, 83, 122, 16, 4, 128, 0, 0,
]);

/// UpgradeableLoaderState::Program discriminant.
const LOADER_STATE_PROGRAM: u32 = 2;

pub const IX_CREATE: u8 = 0;
pub const IX_TRANSFER: u8 = 1;
pub const IX_WRITE_PAYLOAD: u8 = 2;
pub const IX_CONSUME: u8 = 3;
pub const IX_ORPHAN_CLOSE: u8 = 4;
pub const IX_APPROVE: u8 = 5;
pub const IX_REVOKE: u8 = 6;
pub const IX_RESIZE: u8 = 7;

// Events (spec §7)
pub const EVENT_DOMAIN: &[u8] = b"ma1";
pub const EV_CREATE: u8 = 0;
pub const EV_TRANSFER: u8 = 1;
pub const EV_WRITE_PAYLOAD: u8 = 2;
pub const EV_CLOSE: u8 = 3;
pub const EV_APPROVE: u8 = 4;
pub const EV_REVOKE: u8 = 5;
pub const EV_RESIZE: u8 = 6;

pub const BY_OWNER: u8 = 0;
pub const BY_DELEGATE: u8 = 1;
pub const BY_AUTHORITY: u8 = 2;

pub const CLOSE_CONSUME: u8 = 0;
pub const CLOSE_ORPHAN: u8 = 1;

// ---------------------------------------------------------------------------
// Errors (spec §9): ProgramError::Custom(ERROR_BASE + code)
// ---------------------------------------------------------------------------

/// "MA" — keeps Mass Asset codes apart from System Program and issuer codes.
pub const ERROR_BASE: u32 = 0x4D41_0000;

#[derive(Clone, Copy)]
#[cfg_attr(test, derive(Debug, PartialEq))]
pub enum MassAssetError {
    InvalidInstruction = 0,
    UnsupportedVersion = 1,
    InvalidFlags = 2,
    InvalidAccountSize = 3,
    InvalidAuthority = 4,
    // 5 is reserved and never used.
    InvalidObjectAddress = 6,
    ObjectAddressInUse = 7,
    InvalidOwner = 8,
    TransferDisabled = 9,
    PayloadOutOfBounds = 10,
    RefundMismatch = 11,
    NamespaceAlive = 12,
    DuplicateAccount = 13,
    ArithmeticOverflow = 14,
    NotMassAsset = 15,
    AccountNotWritable = 16,
    NamespaceMismatch = 17,
    InsufficientFunds = 18,
    InvalidHeader = 19,
    MissingSigner = 20,
    InvalidSystemProgram = 21,
    InvalidDelegate = 22,
    DelegationNotAllowed = 23,
}

impl MassAssetError {
    fn name(self) -> &'static str {
        match self {
            Self::InvalidInstruction => "MassAsset: InvalidInstruction",
            Self::UnsupportedVersion => "MassAsset: UnsupportedVersion",
            Self::InvalidFlags => "MassAsset: InvalidFlags",
            Self::InvalidAccountSize => "MassAsset: InvalidAccountSize",
            Self::InvalidAuthority => "MassAsset: InvalidAuthority",
            Self::InvalidObjectAddress => "MassAsset: InvalidObjectAddress",
            Self::ObjectAddressInUse => "MassAsset: ObjectAddressInUse",
            Self::InvalidOwner => "MassAsset: InvalidOwner",
            Self::TransferDisabled => "MassAsset: TransferDisabled",
            Self::PayloadOutOfBounds => "MassAsset: PayloadOutOfBounds",
            Self::RefundMismatch => "MassAsset: RefundMismatch",
            Self::NamespaceAlive => "MassAsset: NamespaceAlive",
            Self::DuplicateAccount => "MassAsset: DuplicateAccount",
            Self::ArithmeticOverflow => "MassAsset: ArithmeticOverflow",
            Self::NotMassAsset => "MassAsset: NotMassAsset",
            Self::AccountNotWritable => "MassAsset: AccountNotWritable",
            Self::NamespaceMismatch => "MassAsset: NamespaceMismatch",
            Self::InsufficientFunds => "MassAsset: InsufficientFunds",
            Self::InvalidHeader => "MassAsset: InvalidHeader",
            Self::MissingSigner => "MassAsset: MissingSigner",
            Self::InvalidSystemProgram => "MassAsset: InvalidSystemProgram",
            Self::InvalidDelegate => "MassAsset: InvalidDelegate",
            Self::DelegationNotAllowed => "MassAsset: DelegationNotAllowed",
        }
    }
}

impl From<MassAssetError> for ProgramError {
    fn from(e: MassAssetError) -> Self {
        ProgramError::Custom(ERROR_BASE + e as u32)
    }
}

/// Log the error name (static string, no formatting) and return it.
fn err(e: MassAssetError) -> ProgramError {
    msg!(e.name());
    e.into()
}

fn fail(e: MassAssetError) -> ProgramResult {
    Err(err(e))
}

// ---------------------------------------------------------------------------
// Entrypoint
// ---------------------------------------------------------------------------

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    let (&tag, rest) = match instruction_data.split_first() {
        Some(x) => x,
        None => return fail(MassAssetError::InvalidInstruction),
    };

    match tag {
        IX_CREATE => process_create(program_id, accounts, rest),
        IX_TRANSFER => process_transfer(program_id, accounts, rest),
        IX_WRITE_PAYLOAD => process_write_payload(program_id, accounts, rest),
        IX_CONSUME => process_consume(program_id, accounts, rest),
        IX_ORPHAN_CLOSE => process_orphan_close(program_id, accounts, rest),
        IX_APPROVE => process_approve(program_id, accounts, rest),
        IX_REVOKE => process_revoke(program_id, accounts, rest),
        IX_RESIZE => process_resize(program_id, accounts, rest),
        _ => fail(MassAssetError::InvalidInstruction),
    }
}

// ---------------------------------------------------------------------------
// System Program instructions, encoded by hand (no bincode in the binary).
// Encoding: u32 LE variant index, then fields LE. Verified against
// solana-system-interface in the host unit tests below.
// ---------------------------------------------------------------------------

pub fn sys_create_account(from: &Pubkey, to: &Pubkey, lamports: u64, space: u64, owner: &Pubkey) -> Instruction {
    let mut data = Vec::with_capacity(52);
    data.extend_from_slice(&0u32.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    data.extend_from_slice(&space.to_le_bytes());
    data.extend_from_slice(owner.as_ref());
    Instruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(*from, true), AccountMeta::new(*to, true)],
        data,
    }
}

pub fn sys_assign(account: &Pubkey, owner: &Pubkey) -> Instruction {
    let mut data = Vec::with_capacity(36);
    data.extend_from_slice(&1u32.to_le_bytes());
    data.extend_from_slice(owner.as_ref());
    Instruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(*account, true)],
        data,
    }
}

pub fn sys_transfer(from: &Pubkey, to: &Pubkey, lamports: u64) -> Instruction {
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&2u32.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    Instruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(*from, true), AccountMeta::new(*to, false)],
        data,
    }
}

pub fn sys_allocate(account: &Pubkey, space: u64) -> Instruction {
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&8u32.to_le_bytes());
    data.extend_from_slice(&space.to_le_bytes());
    Instruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(*account, true)],
        data,
    }
}

// ---------------------------------------------------------------------------
// Events (spec §7). Each encoder hands its segments to `sink`; the program passes
// `sol_log_data`, the host tests capture the bytes.
// ---------------------------------------------------------------------------

pub fn ev_create(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, namespace: &Pubkey, owner: &Pubkey, mode: u8, payload_len: u16) {
    sink(&[EVENT_DOMAIN, &[EV_CREATE], object.as_ref(), namespace.as_ref(), owner.as_ref(), &[mode], &payload_len.to_le_bytes()]);
}

pub fn ev_transfer(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, from: &Pubkey, to: &Pubkey, by: u8) {
    sink(&[EVENT_DOMAIN, &[EV_TRANSFER], object.as_ref(), from.as_ref(), to.as_ref(), &[by]]);
}

pub fn ev_write_payload(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, offset: u16, len: u16) {
    sink(&[EVENT_DOMAIN, &[EV_WRITE_PAYLOAD], object.as_ref(), &offset.to_le_bytes(), &len.to_le_bytes()]);
}

pub fn ev_close(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, owner: &Pubkey, lamports: u64, reason: u8) {
    sink(&[EVENT_DOMAIN, &[EV_CLOSE], object.as_ref(), owner.as_ref(), &lamports.to_le_bytes(), &[reason]]);
}

pub fn ev_approve(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, owner: &Pubkey, delegate: &Pubkey) {
    sink(&[EVENT_DOMAIN, &[EV_APPROVE], object.as_ref(), owner.as_ref(), delegate.as_ref()]);
}

pub fn ev_revoke(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, by: u8, previous: &Pubkey) {
    sink(&[EVENT_DOMAIN, &[EV_REVOKE], object.as_ref(), &[by], previous.as_ref()]);
}

pub fn ev_resize(sink: &mut dyn FnMut(&[&[u8]]), object: &Pubkey, old_len: u16, new_len: u16, topup: u64) {
    sink(&[EVENT_DOMAIN, &[EV_RESIZE], object.as_ref(), &old_len.to_le_bytes(), &new_len.to_le_bytes(), &topup.to_le_bytes()]);
}

fn log_sink() -> impl FnMut(&[&[u8]]) {
    |segments: &[&[u8]]| sol_log_data(segments)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Canonical authority PDA and its bump (used only by `create`).
pub fn authority_of(namespace: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[AUTHORITY_SEED], namespace)
}

pub fn object_address(program_id: &Pubkey, namespace: &Pubkey, seed: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[OBJECT_SEED, namespace.as_ref(), seed], program_id)
}

fn read_pubkey(data: &[u8], offset: usize) -> Result<Pubkey, ProgramError> {
    let slice = data
        .get(offset..offset + 32)
        .ok_or_else(|| err(MassAssetError::InvalidAccountSize))?;
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(slice);
    Ok(Pubkey::new_from_array(bytes))
}

#[derive(Clone, Copy)]
#[cfg_attr(test, derive(Debug))]
struct Header {
    transfer_mode: u8,
    payload_len: usize,
    namespace: Pubkey,
    owner: Pubkey,
    delegate: Pubkey,
    authority_bump: u8,
}

fn pubkey_at(data: &[u8], offset: usize) -> Pubkey {
    let mut bytes = [0u8; 32];
    bytes.copy_from_slice(&data[offset..offset + 32]);
    Pubkey::new_from_array(bytes)
}

/// Spec §3.3 — pure header validation, in this exact order (unit-tested on host).
fn parse_header(account_owner: &Pubkey, program_id: &Pubkey, data: &[u8]) -> Result<Header, MassAssetError> {
    // V1
    if account_owner != program_id {
        return Err(MassAssetError::NotMassAsset);
    }
    // V2
    if data.len() < HEADER_LEN {
        return Err(MassAssetError::InvalidAccountSize);
    }
    // V3
    if data[OFF_VERSION] != VERSION {
        return Err(MassAssetError::UnsupportedVersion);
    }
    // V4
    let flags = data[OFF_FLAGS];
    let transfer_mode = flags & TRANSFER_MODE_MASK;
    if flags & RESERVED_FLAGS_MASK != 0 || transfer_mode > MODE_FROZEN {
        return Err(MassAssetError::InvalidFlags);
    }
    // V5
    if data[OFF_RESERVED..HEADER_LEN].iter().any(|b| *b != 0) {
        return Err(MassAssetError::InvalidHeader);
    }
    // V6
    let payload_len = u16::from_le_bytes([data[OFF_PAYLOAD_LEN], data[OFF_PAYLOAD_LEN + 1]]) as usize;
    if payload_len > MAX_PAYLOAD || data.len() != HEADER_LEN + payload_len {
        return Err(MassAssetError::InvalidAccountSize);
    }
    // V7
    let owner = pubkey_at(data, OFF_OWNER);
    if owner == Pubkey::default() {
        return Err(MassAssetError::InvalidOwner);
    }
    // V8
    let delegate = pubkey_at(data, OFF_DELEGATE);
    if transfer_mode != MODE_OWNER && delegate != Pubkey::default() {
        return Err(MassAssetError::InvalidHeader);
    }
    Ok(Header {
        transfer_mode,
        payload_len,
        namespace: pubkey_at(data, OFF_NAMESPACE),
        owner,
        delegate,
        authority_bump: data[OFF_AUTHORITY_BUMP],
    })
}

fn validate(program_id: &Pubkey, object: &AccountInfo) -> Result<Header, ProgramError> {
    // V1 before borrowing, so a foreign account never yields a borrow error instead of NotMassAsset.
    if object.owner != program_id {
        return Err(err(MassAssetError::NotMassAsset));
    }
    let data = object.try_borrow_data()?;
    parse_header(object.owner, program_id, &data).map_err(err)
}

/// The issuer's authority address for an existing asset: one create_program_address
/// with the canonical bump stored at create (constant cost, spec §3.4).
fn authority_key(header: &Header) -> Option<Pubkey> {
    Pubkey::create_program_address(&[AUTHORITY_SEED, &[header.authority_bump]], &header.namespace).ok()
}

/// Spec §3.4 — pure authority check (unit-tested on host).
fn check_authority(is_signer: bool, key: &Pubkey, header: &Header) -> Result<(), MassAssetError> {
    // A1
    if !is_signer {
        return Err(MassAssetError::InvalidAuthority);
    }
    // A2
    match authority_key(header) {
        Some(expected) if expected == *key => Ok(()),
        _ => Err(MassAssetError::InvalidAuthority),
    }
}

fn require_authority(authority: &AccountInfo, header: &Header) -> ProgramResult {
    check_authority(authority.is_signer, authority.key, header).map_err(err)
}

/// Spec §4.1 T4 — who may transfer, and in which role (pure, unit-tested on host).
fn transfer_role(is_signer: bool, signer: &Pubkey, header: &Header) -> Result<u8, MassAssetError> {
    match header.transfer_mode {
        MODE_OWNER => {
            if !is_signer {
                return Err(MassAssetError::InvalidAuthority);
            }
            if *signer == header.owner {
                Ok(BY_OWNER)
            } else if header.delegate != Pubkey::default() && *signer == header.delegate {
                Ok(BY_DELEGATE)
            } else {
                Err(MassAssetError::InvalidAuthority)
            }
        }
        MODE_NAMESPACE => check_authority(is_signer, signer, header).map(|_| BY_AUTHORITY),
        _ => Err(MassAssetError::TransferDisabled),
    }
}

/// Spec §4.6 X4 — who may revoke (pure, unit-tested on host).
fn revoke_role(is_signer: bool, signer: &Pubkey, header: &Header) -> Result<u8, MassAssetError> {
    if !is_signer {
        return Err(MassAssetError::InvalidAuthority);
    }
    if *signer == header.owner {
        Ok(BY_OWNER)
    } else if header.delegate != Pubkey::default() && *signer == header.delegate {
        Ok(BY_DELEGATE)
    } else {
        Err(MassAssetError::InvalidAuthority)
    }
}

/// Keys that can never be the owner of this asset (spec §4.1 T5).
fn forbidden_owner(key: &Pubkey, object: &Pubkey, program_id: &Pubkey, header: &Header) -> bool {
    *key == Pubkey::default()
        || key == object
        || key == program_id
        || *key == header.namespace
        || Some(*key) == authority_key(header)
}

/// Spec §4.5 D6 — keys that can never be a delegate.
fn forbidden_delegate(key: &Pubkey, object: &Pubkey, program_id: &Pubkey, header: &Header) -> bool {
    *key == header.owner || forbidden_owner(key, object, program_id, header)
}

/// Spec §4.7 Z10 — lamports the payer must add (pure, unit-tested on host).
fn resize_shortfall(rent_new: u64, object_lamports: u64) -> u64 {
    rent_new.saturating_sub(object_lamports)
}

/// Hard close (spec §4.3): overflow guard -> clear -> resize(0) -> move all lamports
/// -> assign(System). Returns the amount moved.
fn hard_close(object: &AccountInfo, destination: &AccountInfo) -> Result<u64, ProgramError> {
    let amount = object.lamports();
    let destination_after = match destination.lamports().checked_add(amount) {
        Some(v) => v,
        None => return Err(err(MassAssetError::ArithmeticOverflow)),
    };

    object.try_borrow_mut_data()?.fill(0);
    object.resize(0)?;

    **destination.try_borrow_mut_lamports()? = destination_after;
    **object.try_borrow_mut_lamports()? = 0;

    object.assign(&SYSTEM_PROGRAM_ID);
    Ok(amount)
}

// ---------------------------------------------------------------------------
// 4.0 create
// ---------------------------------------------------------------------------
// data: seed[32] | transfer_mode u8 | payload_len u16 | owner[32] | payload[payload_len]
// accounts: 0 authority (signer), 1 namespace, 2 payer (signer, writable),
//           3 object (writable), 4 system program

fn process_create(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    const FIXED: usize = 32 + 1 + 2 + 32;
    // C1
    if data.len() < FIXED {
        return fail(MassAssetError::InvalidInstruction);
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&data[0..32]);
    let transfer_mode = data[32];
    let payload_len = u16::from_le_bytes([data[33], data[34]]) as usize;
    let owner = read_pubkey(data, 35)?;
    let payload = &data[FIXED..];

    // C2..C5 — instruction parameters.
    if transfer_mode > MODE_FROZEN {
        return fail(MassAssetError::InvalidFlags);
    }
    if payload_len > MAX_PAYLOAD {
        return fail(MassAssetError::InvalidAccountSize);
    }
    if payload.len() != payload_len {
        return fail(MassAssetError::InvalidInstruction);
    }
    if owner == Pubkey::default() {
        return fail(MassAssetError::InvalidOwner);
    }

    let it = &mut accounts.iter();
    let authority = next_account_info(it)?;
    let namespace = next_account_info(it)?;
    let payer = next_account_info(it)?;
    let object = next_account_info(it)?;
    let system_program_info = next_account_info(it)?;

    // C6 — all four roles pairwise distinct: in particular payer != authority,
    // otherwise the issuer's authority signature would let System debit the authority PDA.
    if object.key == authority.key
        || object.key == payer.key
        || object.key == namespace.key
        || payer.key == authority.key
        || payer.key == namespace.key
        || authority.key == namespace.key
    {
        return fail(MassAssetError::DuplicateAccount);
    }
    // C7 — no unredeemable owner (spec §2.3).
    let (expected_authority, authority_bump) = authority_of(namespace.key);
    if owner == *object.key
        || owner == *program_id
        || owner == *namespace.key
        || owner == expected_authority
    {
        return fail(MassAssetError::InvalidOwner);
    }
    // C8 — the namespace is bound to the program whose canonical authority PDA signed.
    if !authority.is_signer || *authority.key != expected_authority {
        return fail(MassAssetError::InvalidAuthority);
    }
    // C9..C11
    if !payer.is_signer {
        return fail(MassAssetError::MissingSigner);
    }
    if !payer.is_writable || !object.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    if *system_program_info.key != SYSTEM_PROGRAM_ID {
        return fail(MassAssetError::InvalidSystemProgram);
    }
    // C12 — canonical object bump only.
    let (expected_object, object_bump) = object_address(program_id, namespace.key, &seed);
    if *object.key != expected_object {
        return fail(MassAssetError::InvalidObjectAddress);
    }

    // C13 — address state, before reading Rent (spec order C13 then C14).
    let current = object.lamports();
    let prefunded = if current == 0 {
        false
    } else if *object.owner == SYSTEM_PROGRAM_ID && object.data_len() == 0 {
        true
    } else {
        return fail(MassAssetError::ObjectAddressInUse);
    };

    let space = HEADER_LEN + payload_len;
    let required = Rent::get()?.minimum_balance(space);
    let bump_seed = [object_bump];
    let signer_seeds: &[&[u8]] = &[OBJECT_SEED, namespace.key.as_ref(), &seed, &bump_seed];

    // C14 — payer funds. The authority is never passed to a CPI (I11).
    if !prefunded {
        if payer.lamports() < required {
            return fail(MassAssetError::InsufficientFunds);
        }
        invoke_signed(
            &sys_create_account(payer.key, object.key, required, space as u64, program_id),
            &[payer.clone(), object.clone(), system_program_info.clone()],
            &[signer_seeds],
        )?;
    } else {
        // Pre-funded System-owned shell (e.g. after hard close + foreign re-fund).
        if current < required {
            let top_up = required - current;
            if payer.lamports() < top_up {
                return fail(MassAssetError::InsufficientFunds);
            }
            invoke(
                &sys_transfer(payer.key, object.key, top_up),
                &[payer.clone(), object.clone(), system_program_info.clone()],
            )?;
        }
        invoke_signed(
            &sys_allocate(object.key, space as u64),
            &[object.clone(), system_program_info.clone()],
            &[signer_seeds],
        )?;
        invoke_signed(
            &sys_assign(object.key, program_id),
            &[object.clone(), system_program_info.clone()],
            &[signer_seeds],
        )?;
    }

    if object.owner != program_id || object.data_len() != space {
        return fail(MassAssetError::InvalidAccountSize);
    }

    {
        let mut out = object.try_borrow_mut_data()?;
        out[OFF_VERSION] = VERSION;
        out[OFF_FLAGS] = transfer_mode;
        out[OFF_PAYLOAD_LEN..OFF_PAYLOAD_LEN + 2].copy_from_slice(&(payload_len as u16).to_le_bytes());
        out[OFF_NAMESPACE..OFF_NAMESPACE + 32].copy_from_slice(namespace.key.as_ref());
        out[OFF_OWNER..OFF_OWNER + 32].copy_from_slice(owner.as_ref());
        out[OFF_DELEGATE..OFF_DELEGATE + 32].fill(0);
        out[OFF_AUTHORITY_BUMP] = authority_bump;
        out[OFF_RESERVED..HEADER_LEN].fill(0);
        out[HEADER_LEN..].copy_from_slice(payload);
    }

    ev_create(&mut log_sink(), object.key, namespace.key, &owner, transfer_mode, payload_len as u16);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.1 transfer
// ---------------------------------------------------------------------------
// data: new_owner[32]
// accounts: 0 object (writable), 1 signer

fn process_transfer(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // T1
    if data.len() != 32 {
        return fail(MassAssetError::InvalidInstruction);
    }
    let new_owner = read_pubkey(data, 0)?;

    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let signer = next_account_info(it)?;

    // T2..T3
    if !object.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    // T4 — against the CURRENT stored owner and delegate.
    let by = transfer_role(signer.is_signer, signer.key, &header).map_err(err)?;
    // T5
    if forbidden_owner(&new_owner, object.key, program_id, &header) {
        return fail(MassAssetError::InvalidOwner);
    }

    {
        let mut out = object.try_borrow_mut_data()?;
        out[OFF_OWNER..OFF_OWNER + 32].copy_from_slice(new_owner.as_ref());
        // Every transfer clears the delegate (I7).
        out[OFF_DELEGATE..OFF_DELEGATE + 32].fill(0);
    }

    ev_transfer(&mut log_sink(), object.key, &header.owner, &new_owner, by);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.2 write_payload
// ---------------------------------------------------------------------------
// data: offset u16 | bytes[..]
// accounts: 0 object (writable), 1 authority (signer)

fn process_write_payload(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // W1
    if data.len() < 2 {
        return fail(MassAssetError::InvalidInstruction);
    }
    let offset = u16::from_le_bytes([data[0], data[1]]) as usize;
    let bytes = &data[2..];

    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let authority = next_account_info(it)?;

    // W2..W4
    if !object.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    require_authority(authority, &header)?;

    // W5
    let end = match offset.checked_add(bytes.len()) {
        Some(e) if e <= header.payload_len => e,
        _ => return fail(MassAssetError::PayloadOutOfBounds),
    };

    object.try_borrow_mut_data()?[HEADER_LEN + offset..HEADER_LEN + end].copy_from_slice(bytes);

    // offset <= end <= payload_len <= 1024, so both fit in u16.
    ev_write_payload(&mut log_sink(), object.key, offset as u16, bytes.len() as u16);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.3 consume
// ---------------------------------------------------------------------------
// accounts: 0 object (writable), 1 authority (signer), 2 owner_account (writable)

fn process_consume(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // K1
    if !data.is_empty() {
        return fail(MassAssetError::InvalidInstruction);
    }
    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let authority = next_account_info(it)?;
    let owner_account = next_account_info(it)?;

    // K2..K4
    if !object.is_writable || !owner_account.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    require_authority(authority, &header)?;
    // K5 — rent goes to the current stored owner only.
    if *owner_account.key != header.owner {
        return fail(MassAssetError::RefundMismatch);
    }
    // K6 (defence in depth; owner == object is rejected at create/transfer)
    if owner_account.key == object.key {
        return fail(MassAssetError::DuplicateAccount);
    }

    let amount = hard_close(object, owner_account)?;
    ev_close(&mut log_sink(), object.key, &header.owner, amount, CLOSE_CONSUME);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.4 orphan_close
// ---------------------------------------------------------------------------
// accounts: 0 object (writable), 1 owner (signer, writable), 2 namespace,
//           3 namespace_programdata

fn process_orphan_close(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // O1
    if !data.is_empty() {
        return fail(MassAssetError::InvalidInstruction);
    }
    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let owner = next_account_info(it)?;
    let namespace = next_account_info(it)?;
    let programdata = next_account_info(it)?;

    // O2..O3
    if !object.is_writable || !owner.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    // O4 — the owner only, never the delegate.
    if !owner.is_signer || *owner.key != header.owner {
        return fail(MassAssetError::InvalidAuthority);
    }
    // O5
    if *namespace.key != header.namespace {
        return fail(MassAssetError::NamespaceMismatch);
    }
    // O6
    if !namespace_absent(namespace, programdata)? {
        return fail(MassAssetError::NamespaceAlive);
    }

    let amount = hard_close(object, owner)?;
    ev_close(&mut log_sink(), object.key, &header.owner, amount, CLOSE_ORPHAN);
    Ok(())
}

/// Spec §4.4. Ownership-based, not lamport-based: a dead ProgramData address can be
/// re-funded into a System-owned shell, which must still count as absent.
fn namespace_absent(namespace: &AccountInfo, programdata: &AccountInfo) -> Result<bool, ProgramError> {
    if *namespace.owner != BPF_LOADER_UPGRADEABLE {
        return Ok(false);
    }
    let data = namespace.try_borrow_data()?;
    if data.len() < 36 {
        return Ok(false);
    }
    let state = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    if state != LOADER_STATE_PROGRAM {
        return Ok(false);
    }
    let recorded = read_pubkey(&data, 4)?;
    if *programdata.key != recorded {
        return Ok(false);
    }
    Ok(*programdata.owner != BPF_LOADER_UPGRADEABLE)
}

// ---------------------------------------------------------------------------
// 4.5 approve
// ---------------------------------------------------------------------------
// data: delegate[32]
// accounts: 0 object (writable), 1 owner (signer)

fn process_approve(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // D1
    if data.len() != 32 {
        return fail(MassAssetError::InvalidInstruction);
    }
    let delegate = read_pubkey(data, 0)?;

    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let owner = next_account_info(it)?;

    // D2..D3
    if !object.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    // D4
    if header.transfer_mode != MODE_OWNER {
        return fail(MassAssetError::DelegationNotAllowed);
    }
    // D5
    if !owner.is_signer || *owner.key != header.owner {
        return fail(MassAssetError::InvalidAuthority);
    }
    // D6
    if forbidden_delegate(&delegate, object.key, program_id, &header) {
        return fail(MassAssetError::InvalidDelegate);
    }

    object.try_borrow_mut_data()?[OFF_DELEGATE..OFF_DELEGATE + 32].copy_from_slice(delegate.as_ref());
    ev_approve(&mut log_sink(), object.key, &header.owner, &delegate);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.6 revoke
// ---------------------------------------------------------------------------
// data: none
// accounts: 0 object (writable), 1 signer (owner or current delegate)

fn process_revoke(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // X1
    if !data.is_empty() {
        return fail(MassAssetError::InvalidInstruction);
    }
    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let signer = next_account_info(it)?;

    // X2..X3
    if !object.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    let header = validate(program_id, object)?;
    // X4
    let by = revoke_role(signer.is_signer, signer.key, &header).map_err(err)?;

    object.try_borrow_mut_data()?[OFF_DELEGATE..OFF_DELEGATE + 32].fill(0);
    ev_revoke(&mut log_sink(), object.key, by, &header.delegate);
    Ok(())
}

// ---------------------------------------------------------------------------
// 4.7 resize
// ---------------------------------------------------------------------------
// data: new_payload_len u16
// accounts: 0 object (writable), 1 authority (signer), 2 payer (signer, writable),
//           3 system program

fn process_resize(program_id: &Pubkey, accounts: &[AccountInfo], data: &[u8]) -> ProgramResult {
    // Z1
    if data.len() != 2 {
        return fail(MassAssetError::InvalidInstruction);
    }
    let new_len = u16::from_le_bytes([data[0], data[1]]) as usize;
    // Z2
    if new_len > MAX_PAYLOAD {
        return fail(MassAssetError::InvalidAccountSize);
    }

    let it = &mut accounts.iter();
    let object = next_account_info(it)?;
    let authority = next_account_info(it)?;
    let payer = next_account_info(it)?;
    let system_program_info = next_account_info(it)?;

    // Z3 — payer != authority keeps the authority PDA out of the System CPI.
    if object.key == authority.key || object.key == payer.key || payer.key == authority.key {
        return fail(MassAssetError::DuplicateAccount);
    }
    // Z4
    if !object.is_writable || !payer.is_writable {
        return fail(MassAssetError::AccountNotWritable);
    }
    // Z5..Z6
    let header = validate(program_id, object)?;
    require_authority(authority, &header)?;
    // Z7 — grow only.
    if new_len <= header.payload_len {
        return fail(MassAssetError::InvalidAccountSize);
    }
    // Z8
    if !payer.is_signer {
        return fail(MassAssetError::MissingSigner);
    }
    // Z9
    if *system_program_info.key != SYSTEM_PROGRAM_ID {
        return fail(MassAssetError::InvalidSystemProgram);
    }
    // Z10
    let new_space = HEADER_LEN + new_len;
    let shortfall = resize_shortfall(Rent::get()?.minimum_balance(new_space), object.lamports());
    if payer.lamports() < shortfall {
        return fail(MassAssetError::InsufficientFunds);
    }

    // Effect 1 — top up from the payer; no seeds, the authority is not passed (I11).
    if shortfall > 0 {
        invoke(
            &sys_transfer(payer.key, object.key, shortfall),
            &[payer.clone(), object.clone(), system_program_info.clone()],
        )?;
    }
    // Effect 2 — grow; existing bytes kept, new bytes zeroed explicitly.
    let old_space = HEADER_LEN + header.payload_len;
    object.resize(new_space)?;
    {
        let mut out = object.try_borrow_mut_data()?;
        out[old_space..new_space].fill(0);
        // Effect 3
        out[OFF_PAYLOAD_LEN..OFF_PAYLOAD_LEN + 2].copy_from_slice(&(new_len as u16).to_le_bytes());
    }

    ev_resize(&mut log_sink(), object.key, header.payload_len as u16, new_len as u16, shortfall);
    Ok(())
}

// ---------------------------------------------------------------------------
// Host unit tests: `cargo test` (not part of the SBF binary).
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use solana_system_interface::instruction as si;

    fn k(n: u8) -> Pubkey {
        Pubkey::new_from_array([n; 32])
    }

    // ---- System instruction encodings ------------------------------------------

    #[test]
    fn system_create_account_matches_library() {
        assert_eq!(
            sys_create_account(&k(1), &k(2), 1_948_800, 152, &k(3)),
            si::create_account(&k(1), &k(2), 1_948_800, 152, &k(3))
        );
    }

    #[test]
    fn system_transfer_matches_library() {
        assert_eq!(sys_transfer(&k(1), &k(2), 111_360), si::transfer(&k(1), &k(2), 111_360));
    }

    #[test]
    fn system_allocate_matches_library() {
        assert_eq!(sys_allocate(&k(4), 152), si::allocate(&k(4), 152));
    }

    #[test]
    fn system_assign_matches_library() {
        assert_eq!(sys_assign(&k(4), &k(5)), si::assign(&k(4), &k(5)));
    }

    #[test]
    fn system_program_id_is_all_zero() {
        assert_eq!(SYSTEM_PROGRAM_ID, solana_system_interface::program::ID);
    }

    #[test]
    fn loader_id_decodes() {
        assert_eq!(BPF_LOADER_UPGRADEABLE.to_string(), "BPFLoaderUpgradeab1e11111111111111111111111");
    }

    // ---- Layout -----------------------------------------------------------------

    #[test]
    fn layout_constants() {
        assert_eq!(HEADER_LEN % 8, 0);
        assert_eq!(OFF_NAMESPACE, 4);
        assert_eq!(OFF_OWNER, 36);
        assert_eq!(OFF_DELEGATE, 68);
        assert_eq!(OFF_AUTHORITY_BUMP, 100);
        assert_eq!(OFF_RESERVED + 3, HEADER_LEN);
        assert_eq!(MassAssetError::InvalidDelegate as u32, 22);
        assert_eq!(MassAssetError::DelegationNotAllowed as u32, 23);
    }

    // ---- §3.3 parse_header ----------------------------------------------------

    const PID: Pubkey = Pubkey::new_from_array([9u8; 32]);

    fn valid_header(payload_len: usize) -> Vec<u8> {
        let mut d = vec![0u8; HEADER_LEN + payload_len];
        d[OFF_VERSION] = VERSION;
        d[OFF_FLAGS] = MODE_OWNER;
        d[OFF_PAYLOAD_LEN..OFF_PAYLOAD_LEN + 2].copy_from_slice(&(payload_len as u16).to_le_bytes());
        d[OFF_NAMESPACE..OFF_NAMESPACE + 32].copy_from_slice(k(7).as_ref());
        d[OFF_OWNER..OFF_OWNER + 32].copy_from_slice(k(8).as_ref());
        d[OFF_AUTHORITY_BUMP] = 255;
        d
    }

    fn parse(d: &[u8]) -> Result<Header, MassAssetError> {
        parse_header(&PID, &PID, d)
    }

    #[test]
    fn v_valid_header_parses() {
        let h = parse(&valid_header(48)).expect("valid");
        assert_eq!(h.payload_len, 48);
        assert_eq!(h.transfer_mode, MODE_OWNER);
        assert_eq!(h.namespace, k(7));
        assert_eq!(h.owner, k(8));
        assert_eq!(h.delegate, Pubkey::default());
        assert_eq!(h.authority_bump, 255);
        assert!(parse(&valid_header(0)).is_ok());
        assert!(parse(&valid_header(MAX_PAYLOAD)).is_ok());
    }

    #[test]
    fn v1_not_mass_asset() {
        assert_eq!(parse_header(&k(1), &PID, &valid_header(0)).unwrap_err(), MassAssetError::NotMassAsset);
    }

    #[test]
    fn v2_short_account() {
        assert_eq!(parse(&valid_header(0)[..HEADER_LEN - 1]).unwrap_err(), MassAssetError::InvalidAccountSize);
        assert_eq!(parse(&[]).unwrap_err(), MassAssetError::InvalidAccountSize);
        // A format-1 sized account (72 bytes) is too short for format 2.
        assert_eq!(parse(&valid_header(0)[..72]).unwrap_err(), MassAssetError::InvalidAccountSize);
    }

    #[test]
    fn v3_version() {
        for v in [0u8, 1, 3, 255] {
            let mut d = valid_header(0);
            d[OFF_VERSION] = v;
            assert_eq!(parse(&d).unwrap_err(), MassAssetError::UnsupportedVersion);
        }
    }

    #[test]
    fn v4_flags() {
        let mut d = valid_header(0);
        d[OFF_FLAGS] = 3;
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidFlags);
        for bit in 2..8 {
            let mut d = valid_header(0);
            d[OFF_FLAGS] = 1 << bit;
            assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidFlags);
        }
        for mode in [MODE_OWNER, MODE_NAMESPACE, MODE_FROZEN] {
            let mut d = valid_header(0);
            d[OFF_FLAGS] = mode;
            assert!(parse(&d).is_ok());
        }
    }

    #[test]
    fn v5_reserved_bytes() {
        for i in OFF_RESERVED..HEADER_LEN {
            let mut d = valid_header(0);
            d[i] = 1;
            assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidHeader);
        }
    }

    #[test]
    fn v6_payload_len() {
        let mut d = valid_header(48);
        d.push(0);
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidAccountSize);
        let mut d = valid_header(48);
        d.pop();
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidAccountSize);
        let mut d = valid_header(MAX_PAYLOAD + 1);
        d[OFF_PAYLOAD_LEN..OFF_PAYLOAD_LEN + 2].copy_from_slice(&((MAX_PAYLOAD + 1) as u16).to_le_bytes());
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidAccountSize);
    }

    #[test]
    fn v7_default_owner() {
        let mut d = valid_header(0);
        d[OFF_OWNER..OFF_OWNER + 32].fill(0);
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidOwner);
    }

    #[test]
    fn v8_delegate_only_in_owner_mode() {
        for mode in [MODE_NAMESPACE, MODE_FROZEN] {
            let mut d = valid_header(0);
            d[OFF_FLAGS] = mode;
            d[OFF_DELEGATE..OFF_DELEGATE + 32].copy_from_slice(k(5).as_ref());
            assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidHeader);
        }
        let mut d = valid_header(0);
        d[OFF_DELEGATE..OFF_DELEGATE + 32].copy_from_slice(k(5).as_ref());
        assert_eq!(parse(&d).expect("owner mode").delegate, k(5));
    }

    #[test]
    fn zero_filled_account_is_rejected() {
        // I1: an account created through System with owner = Mass Asset holds only zeros.
        for len in [0usize, 104, 200] {
            let d = vec![0u8; len];
            assert!(parse(&d).is_err());
        }
    }

    #[test]
    fn v_check_order() {
        let mut d = valid_header(0);
        d[OFF_VERSION] = 1; // V3
        d[OFF_FLAGS] = 0xFF; // V4
        d[OFF_RESERVED] = 1; // V5
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::UnsupportedVersion);
        d[OFF_VERSION] = VERSION;
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidFlags);
        d[OFF_FLAGS] = 0;
        assert_eq!(parse(&d).unwrap_err(), MassAssetError::InvalidHeader);
        assert_eq!(parse_header(&k(1), &PID, &d).unwrap_err(), MassAssetError::NotMassAsset);
    }

    // ---- §3.4 check_authority -------------------------------------------------

    fn header_for(ns: Pubkey, bump: u8) -> Header {
        Header {
            transfer_mode: MODE_OWNER,
            payload_len: 0,
            namespace: ns,
            owner: k(8),
            delegate: Pubkey::default(),
            authority_bump: bump,
        }
    }

    fn canonical_header() -> (Header, Pubkey) {
        let ns = k(7);
        let (auth, bump) = authority_of(&ns);
        (header_for(ns, bump), auth)
    }

    #[test]
    fn a_authority_canonical_ok() {
        let (h, auth) = canonical_header();
        assert_eq!(authority_key(&h), Some(auth));
        assert!(check_authority(true, &auth, &h).is_ok());
    }

    #[test]
    fn a1_not_signer() {
        let (h, auth) = canonical_header();
        assert_eq!(check_authority(false, &auth, &h).unwrap_err(), MassAssetError::InvalidAuthority);
    }

    #[test]
    fn a2_wrong_key_or_bump() {
        let (h, auth) = canonical_header();
        assert_eq!(check_authority(true, &k(1), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        let (other, _) = authority_of(&k(6));
        assert_eq!(check_authority(true, &other, &h).unwrap_err(), MassAssetError::InvalidAuthority);
        for b in 0..=255u8 {
            if b == h.authority_bump {
                continue;
            }
            let hb = header_for(h.namespace, b);
            assert_ne!(authority_key(&hb), Some(auth));
            assert_eq!(check_authority(true, &auth, &hb).unwrap_err(), MassAssetError::InvalidAuthority);
        }
    }

    // ---- §4.1 T4 transfer_role -----------------------------------------------

    #[test]
    fn t4_owner_mode_roles() {
        let (mut h, auth) = canonical_header();
        // Owner, no delegate.
        assert_eq!(transfer_role(true, &k(8), &h).unwrap(), BY_OWNER);
        assert_eq!(transfer_role(false, &k(8), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        // A random key and the issuer authority cannot transfer in owner mode.
        assert_eq!(transfer_role(true, &k(3), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        assert_eq!(transfer_role(true, &auth, &h).unwrap_err(), MassAssetError::InvalidAuthority);
        // With "no delegate" stored as default, the default key is never a delegate.
        assert_eq!(transfer_role(true, &Pubkey::default(), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        // Delegate set.
        h.delegate = k(5);
        assert_eq!(transfer_role(true, &k(5), &h).unwrap(), BY_DELEGATE);
        assert_eq!(transfer_role(false, &k(5), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        assert_eq!(transfer_role(true, &k(8), &h).unwrap(), BY_OWNER);
    }

    #[test]
    fn t4_namespace_and_frozen() {
        let (mut h, auth) = canonical_header();
        h.transfer_mode = MODE_NAMESPACE;
        assert_eq!(transfer_role(true, &auth, &h).unwrap(), BY_AUTHORITY);
        assert_eq!(transfer_role(true, &k(8), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        h.transfer_mode = MODE_FROZEN;
        assert_eq!(transfer_role(true, &k(8), &h).unwrap_err(), MassAssetError::TransferDisabled);
        assert_eq!(transfer_role(true, &auth, &h).unwrap_err(), MassAssetError::TransferDisabled);
    }

    // ---- T5 / D6 forbidden keys -------------------------------------------------

    #[test]
    fn t5_forbidden_owners() {
        let (h, auth) = canonical_header();
        let obj = k(1);
        for bad in [Pubkey::default(), obj, PID, h.namespace, auth] {
            assert!(forbidden_owner(&bad, &obj, &PID, &h));
        }
        assert!(!forbidden_owner(&k(3), &obj, &PID, &h));
        // The current owner is an allowed transfer target (transfer to self clears the delegate).
        assert!(!forbidden_owner(&h.owner, &obj, &PID, &h));
    }

    #[test]
    fn d6_forbidden_delegates() {
        let (h, auth) = canonical_header();
        let obj = k(1);
        for bad in [Pubkey::default(), h.owner, obj, PID, h.namespace, auth] {
            assert!(forbidden_delegate(&bad, &obj, &PID, &h));
        }
        assert!(!forbidden_delegate(&k(5), &obj, &PID, &h));
    }

    // ---- §4.6 X4 revoke_role ----------------------------------------------------

    #[test]
    fn x4_revoke_roles() {
        let (mut h, auth) = canonical_header();
        // No delegate: the owner may revoke (idempotent), nobody else.
        assert_eq!(revoke_role(true, &k(8), &h).unwrap(), BY_OWNER);
        assert_eq!(revoke_role(true, &Pubkey::default(), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        assert_eq!(revoke_role(true, &auth, &h).unwrap_err(), MassAssetError::InvalidAuthority);
        h.delegate = k(5);
        assert_eq!(revoke_role(true, &k(5), &h).unwrap(), BY_DELEGATE);
        assert_eq!(revoke_role(false, &k(5), &h).unwrap_err(), MassAssetError::InvalidAuthority);
        assert_eq!(revoke_role(true, &k(6), &h).unwrap_err(), MassAssetError::InvalidAuthority);
    }

    // ---- §4.7 Z10 resize_shortfall ----------------------------------------------

    #[test]
    fn z10_shortfall() {
        assert_eq!(resize_shortfall(2_060_160, 1_948_800), 111_360);
        assert_eq!(resize_shortfall(2_060_160, 2_060_160), 0);
        assert_eq!(resize_shortfall(2_060_160, 5_000_000), 0);
        assert_eq!(resize_shortfall(0, 0), 0);
    }

    // ---- §7 events: reference encodings from the spec (§7.2) --------------------

    fn b64(s: &str) -> Vec<u8> {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = Vec::new();
        let mut buf = 0u32;
        let mut bits = 0u32;
        for c in s.bytes() {
            if c == b'=' {
                break;
            }
            let v = A.iter().position(|x| *x == c).expect("base64 char") as u32;
            buf = (buf << 6) | v;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((buf >> bits) as u8);
                buf &= (1 << bits) - 1;
            }
        }
        out
    }

    fn line(s: &str) -> Vec<Vec<u8>> {
        s.strip_prefix("Program data: ").expect("prefix").split(' ').map(b64).collect()
    }

    fn capture(f: impl FnOnce(&mut dyn FnMut(&[&[u8]]))) -> Vec<Vec<u8>> {
        let mut got: Vec<Vec<u8>> = Vec::new();
        let mut calls = 0;
        {
            let mut sink = |segs: &[&[u8]]| {
                calls += 1;
                got = segs.iter().map(|s| s.to_vec()).collect();
            };
            f(&mut sink);
        }
        assert_eq!(calls, 1, "exactly one event");
        got
    }

    #[test]
    fn ev_reference_create() {
        let got = capture(|s| ev_create(s, &k(1), &k(2), &k(3), 0, 48));
        assert_eq!(got, line("Program data: bWEx AA== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= AA== MAA="));
    }

    #[test]
    fn ev_reference_transfer() {
        let got = capture(|s| ev_transfer(s, &k(1), &k(3), &k(4), BY_DELEGATE));
        assert_eq!(got, line("Program data: bWEx AQ== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ= AQ=="));
    }

    #[test]
    fn ev_reference_write_payload() {
        let got = capture(|s| ev_write_payload(s, &k(1), 8, 16));
        assert_eq!(got, line("Program data: bWEx Ag== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= CAA= EAA="));
    }

    #[test]
    fn ev_reference_close() {
        let got = capture(|s| ev_close(s, &k(1), &k(4), 1_948_800, CLOSE_CONSUME));
        assert_eq!(got, line("Program data: bWEx Aw== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ= gLwdAAAAAAA= AA=="));
    }

    #[test]
    fn ev_reference_approve() {
        let got = capture(|s| ev_approve(s, &k(1), &k(3), &k(5)));
        assert_eq!(got, line("Program data: bWEx BA== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM= BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU="));
    }

    #[test]
    fn ev_reference_revoke() {
        let got = capture(|s| ev_revoke(s, &k(1), BY_OWNER, &k(5)));
        assert_eq!(got, line("Program data: bWEx BQ== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= AA== BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU="));
    }

    #[test]
    fn ev_reference_resize() {
        let got = capture(|s| ev_resize(s, &k(1), 48, 64, 111_360));
        assert_eq!(got, line("Program data: bWEx Bg== AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE= MAA= QAA= ALMBAAAAAAA="));
    }

    #[test]
    fn ev_segment_counts() {
        assert_eq!(capture(|s| ev_create(s, &k(1), &k(2), &k(3), 0, 0)).len(), 7);
        assert_eq!(capture(|s| ev_transfer(s, &k(1), &k(2), &k(3), 0)).len(), 6);
        assert_eq!(capture(|s| ev_write_payload(s, &k(1), 0, 0)).len(), 5);
        assert_eq!(capture(|s| ev_close(s, &k(1), &k(2), 0, 0)).len(), 6);
        assert_eq!(capture(|s| ev_approve(s, &k(1), &k(2), &k(3))).len(), 5);
        assert_eq!(capture(|s| ev_revoke(s, &k(1), 0, &k(2))).len(), 5);
        assert_eq!(capture(|s| ev_resize(s, &k(1), 0, 1, 0)).len(), 6);
    }
}
