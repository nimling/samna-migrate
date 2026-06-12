COMMENT ON FUNCTION claimius.create_claim IS 'Creates a new claim. p_sa_access is a bitwise mask: 0x01 owner, 0x02 write, 0x04 read, 0x08 execute, 0x10 deny, 0x20 member. Owner implies write+read+execute. Write implies read+execute. Execute implies read. Member is independent and stands alone.';

COMMENT ON FUNCTION claimius.update_claim IS 'Patches selected fields on a claim. p_sa_access is expanded so owner implies write+read+execute, write implies read+execute, execute implies read. Member bit (0x20) stands alone. Empty p_name and zero p_sa_access are treated as preserve so PATCH callers that send only one field do not wipe the others.';

COMMENT ON COLUMN claimius.claim.sa_access IS 'Bitwise access mask. Bits: 0x01 owner, 0x02 write, 0x04 read, 0x08 execute, 0x10 deny, 0x20 member. When the deny bit is set the other bits enumerate which permissions to subtract.';

COMMENT ON COLUMN claimius.claim_object.sa_access IS 'Bitwise access mask with bits 0x01 owner, 0x02 write, 0x04 read, 0x08 execute, 0x10 deny, 0x20 member; NULL means inherit the claim sa_access at read time.';
