"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "./ConnectButton";

const NAV = [
  { href: "/", label: "Pool" },
  { href: "/borrow", label: "Borrow" },
  { href: "/lend", label: "Lend" },
];

export function SiteHeader() {
  const path = usePathname();
  return (
    <header className="sticky top-0 z-20 border-b-[0.5px] border-line bg-surface/85 backdrop-blur">
      <div className="mx-auto flex w-full max-w-[1180px] items-center justify-between px-4 py-3 sm:px-6">
        <Link href="/" aria-label="TrueLend" className="flex items-center gap-2.5">
          <Image
            src="/truelend-logo.png"
            alt="TrueLend"
            width={132}
            height={74}
            priority
            className="h-7 w-auto object-contain mix-blend-multiply dark:mix-blend-screen dark:invert"
          />
          <span className="hidden font-mono text-[10px] uppercase tracking-[0.18em] text-muted sm:inline">
            v4 · Unichain Sepolia
          </span>
        </Link>

        <div className="flex items-center gap-1.5">
          <nav className="mr-2 flex items-center gap-0.5">
            {NAV.map((l) => {
              const active = l.href === "/" ? path === "/" : path.startsWith(l.href);
              return (
                <Link
                  key={l.href}
                  href={l.href}
                  className="rounded-[6px] px-3 py-1.5 text-[13px] transition-colors"
                  style={{
                    color: active ? "var(--ink)" : "var(--muted)",
                    background: active ? "var(--surface-2)" : "transparent",
                  }}
                >
                  {l.label}
                </Link>
              );
            })}
          </nav>
          <ConnectButton />
        </div>
      </div>
    </header>
  );
}
