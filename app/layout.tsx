import type { ReactNode } from "react";

export default function RootLayout({
  children,
}: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en">
      <head>
        <title>No Broke Dayz runtime probe</title>
      </head>
      <body>{children}</body>
    </html>
  );
}
