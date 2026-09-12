# MK Abuzahra Global Ventures Ltd — Complete System

GitHub Pages-ready static frontend for the private sales and commission management system.

## Included
- Super Admin / Admin / Staff / Advertiser access flow
- Advertiser registration and pending approval
- Sale Claim workflow
- Unique Sale ID and one-time authenticator code
- Customer verification and sale redemption
- Commission lifecycle: PENDING → ELIGIBLE → PAID
- Product management
- System settings
- Company branding/logo
- Supabase Auth + database integration
- Google Search Console verification meta tag
- `sitemap.xml` and `robots.txt`

## GitHub Pages upload
Upload the CONTENTS of this folder to the root of the `main` branch. Do not upload this ZIP as a single file, and do not create another folder around the files.

The repository root must directly contain:
- `index.html`
- `app.js`
- `styles.css`
- `config.js`
- `manifest.json`
- `sw.js`
- `sitemap.xml`
- `robots.txt`
- `assets/logo.png`
- `FINAL_SYSTEM.sql`

GitHub Pages should be set to `main` + `/(root)`.

## Supabase
The frontend uses the publishable browser key in `config.js`. Never put a Supabase secret/service-role key in this frontend.

Run `FINAL_SYSTEM.sql` in the Supabase SQL Editor once. This final SQL is designed around the current `profiles.status` / `super_admin` setup. Do not run the old chapter migration files.

## Google Search Console
The homepage contains the supplied verification tag:
`hnNDYxuEKONol5JdtUdl7gE-esqvRlX9MUyIuzwJU-8`

After this version is live, verify the exact GitHub Pages URL in Search Console using the HTML tag method, then submit:
`/mk-abuzahra-global-ventures/sitemap.xml`

## Important
GitHub Pages hosts the frontend only. Supabase remains the backend/auth/database.
