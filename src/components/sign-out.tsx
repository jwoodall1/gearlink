"use client";

import { useState } from "react";
import { createBrowserClient } from "@supabase/ssr";

export function SignOut() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function logout() {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const supabase = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!);
      const { error } = await supabase.auth.signOut({ scope: "local" });
      if (error) throw error;
      window.location.assign("/login");
    } catch {
      setError("Couldn't sign out. Check your connection and try again.");
      setBusy(false);
    }
  }
  return <div className="account-actions"><button className="sign-out" onClick={logout} disabled={busy} aria-busy={busy}>{busy ? "Signing out…" : "Sign out"}</button>{error && <p className="notice error" role="alert">{error}</p>}</div>;
}
