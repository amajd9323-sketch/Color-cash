# Color Clash

A mobile-first Arabic/English browser game prototype with Solo vs Bot, Color Find, Color Match, and Color Memory rounds. Dark neon interface; installable PWA.

## Run
Open `index.html` or publish this repository with GitHub Pages.

## Online rooms
Create a Supabase project, run `supabase.sql` in its SQL Editor, then configure the deployed page with your Supabase project URL and public anon key. Never expose a service-role key.

**Prototype warning:** room creation/join/start sync is a starter implementation. The SQL policies are permissive and scores are client-side. Before public launch, add Supabase Auth, membership-based RLS, server-side score validation, reconnect handling, room expiry/cleanup, and anti-cheat checks.

## Android
Wrap the web app with Capacitor on a computer with Node.js and Android Studio. Build the Android APK from Android Studio after syncing the Capacitor project.

## Files
- `index.html`: game UI and gameplay
- `manifest.json`: PWA manifest
- `icon.svg`: app icon
- `supabase.sql`: starter database schema
