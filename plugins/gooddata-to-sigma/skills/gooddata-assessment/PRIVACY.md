# Privacy

`gooddata-assessment` is **read-only** and **local**. It calls the GoodData
declarative layout API (`GET /api/v1/layout/...`) with the user's own API token
to read workspace metadata — dataset / metric / insight / dashboard definitions
— and computes counts and complexity tags on the local machine.

- No workspace data (warehouse rows / query results) is read or transmitted.
- Nothing is written back to GoodData.
- No definitions or credentials are sent anywhere except to the user's own
  GoodData host. Output (the readout) stays local.
- The API token is read from the environment / `~/.gooddata_env` and is never
  logged.
