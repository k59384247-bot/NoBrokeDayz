const signupPending =
  "If this address can be registered, check your email for confirmation instructions.";
const signInRejected =
  "Unable to sign in. Check your details, and confirm your email if this is a new account.";
const recoveryPending =
  "If an account uses this address, password recovery instructions will be sent.";

export function safeSignupMessage(error) {
  if (!error || error.code === "user_already_exists") return signupPending;
  if (error.code === "weak_password" || error.code === "validation_failed") {
    return "Check the email and password requirements, then try again.";
  }
  return "We could not start signup. Please try again.";
}

export function safeSignInMessage(error) {
  return error ? signInRejected : "Signed in.";
}

export function safeRecoveryMessage() {
  return recoveryPending;
}
