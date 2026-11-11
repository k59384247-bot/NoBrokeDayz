import Image from "next/image";
import { cookies } from "next/headers";

export const dynamic = "force-dynamic";

export default async function RuntimeProbePage() {
  const cookieValue = (await cookies()).get("nbd_probe")?.value ?? "absent";
  const renderedAt = new Date().toISOString();

  return (
    <main>
      <h1>Workers runtime probe</h1>
      <p id="render-marker">server-rendered-on-worker</p>
      <time id="rendered-at" dateTime={renderedAt}>
        {renderedAt}
      </time>
      <output id="cookie-value">{cookieValue}</output>
      <Image
        src="/runtime-probe.svg"
        alt="Runtime probe image"
        width={32}
        height={32}
        unoptimized
      />
    </main>
  );
}
