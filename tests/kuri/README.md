This directory vendors the `merjs-e2e` test from `justrach/kuri`.

GitHub Actions copies [`merjs_e2e.zig`](/Users/rachpradhan/merjs/tests/kuri/merjs_e2e.zig) into the checked-out Kuri repo before building `kuri` and `merjs-e2e`.

That lets `merjs` evolve its browser E2E assertions locally, without waiting for a separate Kuri PR first.
