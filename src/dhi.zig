/// dhi — Pydantic-style validation types, pulled from the dhi package.
///
/// See https://github.com/justrach/dhi
///
/// Usage in a route handler:
///
///   const UserModel = mer.dhi.Model("User", .{
///       .name  = mer.dhi.Str(.{ .min_length = 1, .max_length = 100 }),
///       .email = mer.dhi.EmailStr,
///       .age   = mer.dhi.Int(i32, .{ .gt = 0, .le = 150 }),
///   });
///   const user = try UserModel.parse(.{ .name = "Alice", .email = "a@b.com", .age = @as(i32, 25) });

// --- Model API (Pydantic-style declarative schemas) --------------------------
const model_mod = @import("dhi_model");

pub const Model        = model_mod.Model;
pub const Str          = model_mod.Str;
pub const Int          = model_mod.Int;
pub const Float        = model_mod.Float;
pub const Bool         = model_mod.Bool;
pub const StrOpts      = model_mod.StrOpts;
pub const IntOpts      = model_mod.IntOpts;
pub const FloatOpts    = model_mod.FloatOpts;
pub const BoolOpts     = model_mod.BoolOpts;
pub const FieldKind    = model_mod.FieldKind;
pub const FieldDesc    = model_mod.FieldDesc;
pub const ValidationError = model_mod.ValidationError;

/// Semantic type aliases (mirrors Pydantic built-in types)
pub const EmailStr        = model_mod.EmailStr;
pub const HttpUrl         = model_mod.HttpUrl;
pub const Uuid            = model_mod.Uuid;
pub const IPv4            = model_mod.IPv4;
pub const IPv6            = model_mod.IPv6;
pub const IsoDate         = model_mod.IsoDate;
pub const IsoDatetime     = model_mod.IsoDatetime;
pub const Base64Str       = model_mod.Base64Str;
pub const PositiveInt     = model_mod.PositiveInt;
pub const NegativeInt     = model_mod.NegativeInt;
pub const NonNegativeInt  = model_mod.NonNegativeInt;
pub const NonPositiveInt  = model_mod.NonPositiveInt;
pub const PositiveFloat   = model_mod.PositiveFloat;
pub const NegativeFloat   = model_mod.NegativeFloat;
pub const NonNegativeFloat = model_mod.NonNegativeFloat;
pub const NonPositiveFloat = model_mod.NonPositiveFloat;
pub const FiniteFloat     = model_mod.FiniteFloat;

// --- Validator API (fine-grained runtime validators) ------------------------
const validator_mod = @import("dhi_validator");

pub const BoundedInt      = validator_mod.BoundedInt;
pub const BoundedString   = validator_mod.BoundedString;
pub const Email           = validator_mod.Email;
pub const ValidationErrors = validator_mod.ValidationErrors;
pub const ValidationResult = validator_mod.ValidationResult;
