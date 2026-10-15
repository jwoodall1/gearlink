import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signIn } from "./actions";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (data?.claims) redirect("/dashboard");
  const { error } = await searchParams;

  return <main className="login-page"><section className="login-card">
    <div className="brand-mark">G</div><p className="eyebrow">GEARLINK / ORGANIZATION</p>
    <h1>Welcome back</h1><p className="muted">Sign in to manage your team's equipment.</p>
    {error && <p className="form-error" role="alert">{error}</p>}
    <form action={signIn} className="login-form">
      <label>Email<input name="email" type="email" autoComplete="email" required /></label>
      <label>Password<input name="password" type="password" autoComplete="current-password" required /></label>
      <button className="button button-primary" type="submit">Sign in <span>↗</span></button>
    </form><p className="form-footnote">Ask your organization administrator for an account.</p>
  </section></main>;
}
