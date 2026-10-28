# Google Calendar setup

Google sync requires a one-time setup on your computer. After that, Calendar can refresh its credentials and sync directly from the tablet over Wi-Fi. You can browse cached events and create, edit, or delete events offline; Google changes wait for a successful sync.

Install Calendar first using the [README](../README.md#set-up-your-tablet). You also need Python 3 and a copy of this repository on your computer to run the authorization helper. The commands below run from the repository root in Linux or WSL and use the tablet's USB address, `10.11.99.1`.

## Create Google credentials

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select your project.
2. Enable the **Google Calendar API**.
3. Configure Google Auth Platform branding and audience. If your external app is in Testing, add the Google account you intend to use as a test user.
4. Create an OAuth client with application type **Desktop app** and download its JSON. This is the client configuration, not yet the credentials Calendar will use on the tablet.
5. Store the download privately outside the repository, for example as `~/.config/remarkable-calendar/client.json`.

## Authorize your account

Run:

```sh
python3 scripts/google-auth.py ~/.config/remarkable-calendar/client.json
```

Open the printed authorization URL in your computer's browser, sign in, and grant **both requested Calendar permissions**: reading calendars/events and editing events. The helper waits up to five minutes for the browser callback and saves the resulting credentials to `~/.config/remarkable-calendar/google.json`.

Keep both files private. The helper refuses to overwrite an existing output. To authorize again or upgrade an older read-only setup, choose a new output:

```sh
python3 scripts/google-auth.py ~/.config/remarkable-calendar/client.json \
  --output ~/.config/remarkable-calendar/google-new.json
```

Use that new filename in the copy command below. If the browser cannot reach the callback in WSL, check Windows-to-WSL localhost forwarding, or run the helper on a Linux desktop.

## Copy credentials to the tablet

Close Calendar, then run:

```sh
ssh root@10.11.99.1 'umask 077; mkdir -p /home/root/.config/remarkable-calendar; chmod 700 /home/root/.config/remarkable-calendar'
scp -p ~/.config/remarkable-calendar/google.json root@10.11.99.1:/home/root/.config/remarkable-calendar/google.json
ssh root@10.11.99.1 'chmod 600 /home/root/.config/remarkable-calendar/google.json'
```

If you used `google-new.json`, replace only the **computer-side** filename in the `scp` command; the tablet destination remains `google.json`. The tablet clock must be correct for secure connections to Google.

## Choose the display timezone

Calendar uses one display timezone for all calendars. On a fresh installation it defaults to UTC. The timezone is shown in Settings, but there is currently no timezone picker.

For a **fresh installation, before saving settings**, initialize your preferred timezone with a first sync. Keep Calendar closed and connect the tablet to Wi-Fi. This example syncs the primary calendar using New York time:

```sh
ssh root@10.11.99.1 '/home/root/xovi/exthome/appload/remarkable-calendar/backend/entry google-sync 2026-10-01 2027-05-01 America/New_York'
```

Replace the dates with a range around today and replace `America/New_York` with your IANA timezone, such as `America/Guatemala` or `Europe/London`. The ending date is exclusive. The app uses this initial timezone when creating its settings; subsequent in-app syncs use the rolling window selected in Settings.

If you have already saved settings, a command-line sync does not overwrite their timezone. Existing configurations can be changed through the [local settings interface](development.md#local-http-interface); this is currently an advanced setup step. Do not run a command-line sync while an in-app sync is running.

## Select calendars and sync

1. Open **Calendar** from AppLoad.
2. Open Settings using the gear icon. The app may discover your calendars automatically; otherwise tap **Refresh list**.
3. Select the calendars you want to show. New calendars found later start unselected.
4. Choose how many months to keep offline. Defaults are one month back and six months ahead.
5. Choose whether to refresh on launch when the saved data is stale. This is a launch-time check, not a continuous scheduled sync.
6. Tap **Save & sync** and wait for completion. Return to Settings to see progress or errors.

Tap the toolbar sync icon whenever you want to refresh while online. Hiding a calendar retains its saved cache. Only dates inside the saved window are available offline; changing the window and syncing replaces that calendar's cached interval.

After an authorization upgrade, complete an online sync before editing existing Google events so Calendar can fetch current event versions and permissions. Calendars shared with read-only access remain read-only.

## Pending edits and sign-in problems

Changes save on the tablet first. Open Settings to review pending operations and sync errors. If Google has a newer event version or calendar access has changed, the change remains queued for review. Discard removes the queued change; it does not undo an operation already accepted by Google.

Google projects in Testing can have expiring authorizations. If sync reports an authorization error, repeat the browser sign-in and replace the tablet credentials using the steps above. To revoke access, remove the authorization from your Google account's third-party connections. There is currently no in-app sign-in or disconnect screen.

For more background, see Google's documentation on [desktop authorization](https://developers.google.com/identity/protocols/oauth2/native-app) and [refresh token expiration](https://developers.google.com/identity/protocols/oauth2#expiration). Build instructions and implementation details are in [Development](development.md).
