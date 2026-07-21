import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const incoming = await headers();
  const host = incoming.get("x-forwarded-host") ?? incoming.get("host") ?? "localhost:3000";
  const protocol = incoming.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const origin = `${protocol}://${host}`;

  return {
    title: "PSUB — Python Security Update Builder",
    description: "A controlled Windows workflow for building verifiable Python 3.10–3.12 security releases.",
    icons: { icon: "/psub-logo.png", shortcut: "/psub-logo.png" },
    openGraph: {
      title: "PSUB — Security releases. Built with proof.",
      description: "Build verifiable Python 3.10–3.12 security releases on Windows.",
      images: [{ url: `${origin}/og.png`, width: 1200, height: 630, alt: "PSUB — Security releases. Built with proof." }],
    },
    twitter: { card: "summary_large_image", images: [`${origin}/og.png`] },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
