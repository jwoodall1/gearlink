"use client";
import { useTransition } from "react";
import { useRouter } from "next/navigation";

export function RetryState({ reset }: { reset: () => void }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return <div className="content"><div className="panel error-state" role="alert"><p className="eyebrow">CONNECTION INTERRUPTED</p><h1>We couldn't load this page</h1><p className="muted">Check your connection and try again. If this continues, contact your program administrator.</p><button className="button button-primary" disabled={pending} onClick={() => startTransition(() => { router.refresh(); reset(); })}>{pending ? "Retrying…" : "Try again"}</button></div></div>;
}
