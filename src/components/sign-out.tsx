"use client";

import { useState } from "react";
import { createBrowserClient } from "@supabase/ssr";

export function SignOut() {
  const [busy, setBusy] = useState(false);
  async function logout() {
    setBusy(true);
    const supabase = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!);
    await supabase.auth.signOut();
    window.location.assign("/login");
  }
  return <button className="sign-out" onClick={logout} disabled={busy}>{busy ? "Signing out…" : "Sign out"}</button>;
}
