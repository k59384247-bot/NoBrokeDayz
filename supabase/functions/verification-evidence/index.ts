import { createVerificationFilesHandler } from "../_shared/verification-files.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const downloadSigningKey = Deno.env.get("NBD_VERIFICATION_DOWNLOAD_HMAC_KEY");

if (!supabaseUrl || !anonKey || !serviceRoleKey || !downloadSigningKey)
  throw new Error("verification evidence server configuration missing");

const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
};

function storagePath(bucket: string, key: string) {
  return `${baseUrl}/storage/v1/object/${bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;
}

async function storageRequest(path: string, init: RequestInit) {
  const response = await fetch(path, {
    ...init,
    headers: { ...serverHeaders, ...init.headers },
  });
  if (!response.ok) throw new Error("private storage operation failed");
  return response;
}

Deno.serve(
  createVerificationFilesHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      if (!response.ok) return null;
      const user = await response.json();
      const payload = token.split(".")[1];
      if (!payload || !/^[A-Za-z0-9_-]+$/.test(payload)) return null;
      const base64 = payload.replaceAll("-", "+").replaceAll("_", "/");
      const decoded = JSON.parse(
        atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
      );
      return { actor: user.id, aal: decoded.aal };
    },
    command: async (name: string, args: Record<string, unknown>) => {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: { ...serverHeaders, "content-type": "application/json" },
        body: JSON.stringify(args),
      });
      const result = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error("verification command failed") as Error & {
          code?: string;
        };
        error.code = result?.message;
        throw error;
      }
      return result;
    },
    storeUpload: async (
      bucket: string,
      key: string,
      bytes: Uint8Array,
      options: { contentType: string; cacheControl: string; upsert: boolean },
    ) => {
      await storageRequest(storagePath(bucket, key), {
        method: "POST",
        headers: {
          "content-type": options.contentType,
          "cache-control": options.cacheControl,
          "x-upsert": String(options.upsert),
        },
        body: bytes,
      });
    },
    readUpload: async (bucket: string, key: string) => {
      const response = await storageRequest(storagePath(bucket, key), {
        method: "GET",
      });
      return new Uint8Array(await response.arrayBuffer());
    },
    removeUpload: async (bucket: string, key: string) => {
      await storageRequest(`${baseUrl}/storage/v1/object/${bucket}`, {
        method: "DELETE",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ prefixes: [key] }),
      });
    },
    downloadSigningKey,
    downloadBaseUrl: `${baseUrl}/functions/v1/verification-evidence`,
  }),
);
