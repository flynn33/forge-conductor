# Home template

Copy contents into `%USERPROFILE%\.forge-conductor` (or merge) on install.

Do not overwrite a live home blindly — preserve `store.sqlite`, corpora, and secrets.

After copy:

1. Run `npm ci` inside `telemetry/`
2. Register elevated RAM disk task (admin)
3. Point launchers at installed venv paths
4. Start telemetry / open dashboard
