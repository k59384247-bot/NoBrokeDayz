import { normalizeNigerianPhone } from "./phone-number.mjs";

async function currentEmailUser(auth) {
  let result = await auth.getUser();
  if (result.error) {
    const refreshed = await auth.refreshSession();
    if (refreshed.error) return { error: safeError("authentication_required") };
    result = await auth.getUser();
  }
  if (result.error) return { error: safeError("authentication_required") };
  if (!result.data.user?.email || !result.data.user.email_confirmed_at) {
    return { error: safeError("email_confirmation_required") };
  }
  return { user: result.data.user };
}

function safeError(code) {
  const messages = {
    authentication_required: "Sign in again before changing your phone.",
    email_confirmation_required:
      "Confirm your login email before changing your phone.",
    rate_limited: "Wait before requesting or trying another phone code.",
    phone_change_unavailable:
      "We could not start phone verification. Try again later.",
    phone_verification_failed:
      "That code is invalid, expired, or already used.",
  };
  return Object.assign(new Error(messages[code]), { code });
}

export async function requestMyPhoneChange(auth, phone) {
  const normalizedPhone = normalizeNigerianPhone(phone);
  const { error } = await currentEmailUser(auth);
  if (error) return { data: null, error };
  const result = await auth.updateUser({ phone: normalizedPhone });
  if (result.error) {
    return {
      data: null,
      error: safeError(
        result.error.status === 429
          ? "rate_limited"
          : "phone_change_unavailable",
      ),
    };
  }
  return {
    data: { status: "pending", phone: normalizedPhone },
    error: null,
  };
}

export async function confirmMyPhoneChange(auth, phone, token) {
  const normalizedPhone = normalizeNigerianPhone(phone);
  if (typeof token !== "string" || !/^\d{6}$/.test(token)) {
    return { data: null, error: new Error("invalid verification code") };
  }
  const { error } = await currentEmailUser(auth);
  if (error) return { data: null, error };
  const result = await auth.verifyOtp({
    phone: normalizedPhone,
    token,
    type: "phone_change",
  });
  if (
    result.error ||
    !result.data?.user?.id ||
    !result.data.user.phone_confirmed_at
  ) {
    return { data: null, error: safeError("phone_verification_failed") };
  }
  return {
    data: {
      status: "auth_confirmed",
      userId: result.data.user.id,
      phone: normalizeNigerianPhone(result.data.user.phone),
    },
    error: null,
  };
}
