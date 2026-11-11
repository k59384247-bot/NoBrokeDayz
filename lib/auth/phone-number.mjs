export function normalizeNigerianPhone(value) {
  if (typeof value !== "string") throw new Error("invalid phone number");
  const input = value.trim();
  if (!/^\+?[0-9 ()-]+$/.test(input)) throw new Error("invalid phone number");

  let digits = input.replace(/\D/g, "");
  if (digits.startsWith("0")) digits = `234${digits.slice(1)}`;
  if (!digits.startsWith("234")) throw new Error("invalid phone number");

  const nationalNumber = digits.slice(3);
  if (!/^[789][0-9]{9}$/.test(nationalNumber)) {
    throw new Error("invalid phone number");
  }
  return `+234${nationalNumber}`;
}
