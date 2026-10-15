import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = {
  title: "GearLink | Equipment management",
  description: "Manage your organization's athletic equipment and assignments.",
  icons: { icon: "/brand/gearlink-symbol.png", apple: "/brand/gearlink-symbol.png" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
