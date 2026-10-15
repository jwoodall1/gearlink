"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function signIn(formData: FormData) {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) redirect(`/login?error=${encodeURIComponent("Email or password was not accepted.")}`);
  redirect("/dashboard");
}

export async function createOrganization(formData: FormData) {
  const name = String(formData.get("organization") ?? "").trim();
  if (name.length < 2 || name.length > 120) redirect("/dashboard?setup=invalid");
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error || !data?.claims) redirect("/login");
  const { error: createError } = await supabase.rpc("create_organization", { org_name: name });
  if (createError) redirect("/dashboard?setup=error");
  redirect("/dashboard?setup=complete");
}
