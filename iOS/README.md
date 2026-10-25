# GearLink iOS app

SwiftUI app for existing GearLink accounts. Sign in with the same email and password used on the web dashboard. The signed-in app includes a dashboard, editable roster, and Settings with appearance options and sign-out.

## Open and run

1. Open `GearLink.xcodeproj` in Xcode.
2. If `Config/Local.xcconfig` is missing, copy `Config/Local.xcconfig.example` to it.
3. Use the same Supabase URL and publishable key as the web dashboard (`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` in the root `.env.local`). Preserve the example's `https:/$()/` syntax: it prevents Xcode from treating `//` as a comment.
4. Choose an iPhone simulator and press Run.
5. Sign in using the existing admin account's email and password.

The app uses Supabase Auth; it does not create accounts or store passwords. Supabase manages session persistence and token refresh. Signing out ends this app's session without signing the user out of the web dashboard.

The displayed name comes from the Auth user's metadata, in order: `username`, `display_name`, `full_name`, `name`. If these are absent, the app displays the account email. These fields are display values only; database permissions remain controlled by Supabase Row Level Security.

Missing or placeholder configuration shows a setup message. Use only a publishable key, never a secret or service role key. `Local.xcconfig` is ignored by Git.

## Manual checks

- Sign in with the admin account and confirm the logo and account name appear.
- Close and reopen the app; the session should be restored.
- Sign out; confirm the email/password form returns.
- Enter an incorrect password; confirm an error appears and another attempt is possible.
- Disable networking and attempt to sign in; confirm the app reports the connection failure.

The official `supabase-swift` package is resolved by Xcode. Commit its `Package.resolved` file to keep dependency versions consistent.

## Dashboard and roster

After sign-in, Overview shows the organization, active athlete count, and team count using the web dashboard's blue and white palette. Team roster supports searching by name or team and optionally showing inactive athletes. Administrators can add athletes, edit their names and team, and change active status. Coaches can view the roster. Open scanner opens the read-only NFC scanner described below.

The app uses the signed-in user's earliest organization membership and explicitly scopes roster reads and writes to that organization. Existing Supabase RLS policies enforce access. Saves return the database record before the interface reports success. Pull down on Overview or Team roster to fetch changes made elsewhere; reload the web roster page to see mobile edits. No Realtime subscription is installed.

Additional checks: add an athlete, edit its name/team, clear its team, and toggle active status. Refresh the web roster to confirm saved changes (inactive athletes are excluded there). Enable “Include inactive athletes” on iOS to reactivate an athlete. Verify a coach account can view but cannot edit, and verify failed saves leave the editor open with its entered values intact.

## Settings and appearance

The bottom tab bar contains Dashboard, Athletes, and Settings. Settings shows the signed-in account and provides sign-out. Appearance offers System (the default), Light, and Dark; the choice is saved on this device and also applies to the login screen. System follows device appearance changes automatically. Dashboard cards, text, roster screens, forms, and the scanner support both appearances.

Check each appearance choice in Settings, reopen the app to confirm the selection persists, and change the device appearance while System is selected. Verify sign-out returns to the login screen with the selected appearance.


## NFC scanner

NFC scanning is enabled. Debug and Release both use `GearLink/GearLink.entitlements`, which requests the TAG reader entitlement. The app retains its NFC usage description and ISO 7816 NDEF application identifier.

Select your approved Apple Developer Program team in Xcode's Signing & Capabilities and use automatic signing. Ensure the app identifier and provisioning profile include Near Field Communication Tag Reading. If Xcode still uses a Personal Team profile, refresh the account/team selection and regenerate the development provisioning profile before installing on your iPhone.

Open Dashboard → Open scanner → Scan tag on a compatible physical iPhone. Hold the top of the phone near one tag until the system scanning sheet closes. Simulator cannot read physical tags.

The result shows the tag identifier in hexadecimal (in the byte order returned by Core NFC), tag family, NDEF status/capacity, and records. Text and URI records are decoded; text MIME and JSON records are shown as UTF-8 when possible. Every record includes raw payload hex and an optional record identifier. A tag identifier and an NDEF record identifier are different fields. URLs are displayed without automatically opening them.

This version polls ISO 14443 and ISO 15693 tags, including common NTAG/MIFARE tags supported by iOS. The standard NDEF application ID is configured for ISO 7816 NDEF tags. FeliCa polling, arbitrary smart-card applications, password-protected memory, and proprietary raw-memory reads are not implemented. An unsupported NDEF result does not mean a tag is physically empty. Some tags expose randomized identifiers; do not assume every scanned identifier is a permanent equipment identity.

The scanner reads only. It does not write tags, register equipment, or save scan results to Supabase. The latest result stays on the scanner screen until another scan starts or the screen is closed.

### Signing and device testing

The project includes the NFC usage description and TAG reader entitlement for Near Field Communication Tag Reading. Use your development team with automatic signing in Xcode. The iPhone provisioning profile must include NFC Tag Reading; Xcode may need to regenerate it. An unsigned Simulator build cannot validate the device profile or physical NFC behavior.

Check on iPhone:

- Scan a tag containing a known text or URL record and compare the ID/content with a trusted reader.
- Scan an empty NDEF tag and a tag without NDEF support; confirm the ID and explanation remain visible.
- Scan multiple-record and binary-record tags; expand raw payloads.
- Cancel the system sheet and scan again; also retry after a timeout or moving the tag away during reading.
- Verify the scanner remains readable in Light, Dark, and System appearance.


## Phase 1 presentation update

Overview now reads exact equipment/availability/open-assignment counts and maintenance/repair flags from the current organization. Retired items are excluded from attention. Expand a flagged item to inspect its recorded details. Failed refreshes retain previous equipment data with a warning; the update timestamp identifies the last successful load. These are read-only summaries.

Athletes is directly accessible from the tab bar. Shared semantic colors/cards/messages support the existing appearance preference, and metrics stack at accessibility text sizes. Roster saves provide success feedback after backend confirmation; cancelling changed athlete fields asks before discarding them.

See `../docs/phase-1-status.md` for validation and outstanding runtime device QA.
