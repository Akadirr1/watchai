import QRCode from "qrcode";
import type { FastifyRequest } from "fastify";

/**
 * The QR the watch displays.
 *
 * It encodes a URL rather than raw pairing data so the **iPhone's own Camera app** can
 * scan it — iOS Safari has no `BarcodeDetector`, so an in-page scanner would have been
 * broken on the one device that matters.
 *
 * Rendered here rather than on the watch for a plain reason: a hand-written QR encoder
 * was attempted and was subtly wrong in a way that only a real decoder caught. A correct
 * QR matters more than avoiding one well-tested dependency, and this keeps the watch to
 * "fetch a PNG and draw it".
 */

/**
 * The public origin to embed. Prefers an explicit `PUBLIC_URL`, because deriving it from
 * proxy headers is only as trustworthy as the proxy in front of you.
 */
export function publicOrigin(request: FastifyRequest): string {
  const configured = process.env["PUBLIC_URL"];
  if (configured) return configured.replace(/\/+$/, "");
  return `${request.protocol}://${request.hostname}`;
}

export function pairingURL(origin: string, code: string): string {
  return `${origin}/pair?c=${encodeURIComponent(code)}`;
}

export function renderPairingQR(url: string): Promise<Buffer> {
  return QRCode.toBuffer(url, {
    errorCorrectionLevel: "M",
    margin: 2,
    // Comfortably scannable from a 41mm screen without being larger than the payload needs.
    width: 360,
    color: { dark: "#000000ff", light: "#ffffffff" },
  });
}
