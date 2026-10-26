# Contributing to xGEO

**xGEO Core is open source, but not open to contributions.** You are welcome
to download ([xgeo-core.zip](https://kw-wargame.github.io/xgeo/core/xgeo-core.zip)) or fork Core and change your own copy as you like, under the
Apache License 2.0 (`LICENSE`). Changes to this repository are made only by
the maintainer: pull requests are not accepted and will be closed unread.

## What is welcome: issues

Please do open an issue for:

- **a bug:** something in the game or in Core that does not work;
- **a physics or source problem:** a model, number or citation that looks
  wrong, with a public source that shows it;
- **a feature request:** something you would like in xGEO Live or Core.

Use the issue templates. Cite public material only: do not post
classified, export-controlled or otherwise restricted information.

## If you build on Core

Fork it or download it and work in your own copy. Keep the `LICENSE`,
`LICENSE-APACHE` and `NOTICE` files, say what you changed, and do not call
your version xGEO. "Based on xGEO Core" is fine.

The rules this project holds itself to are worth keeping in yours:

- every number is either sourced or labelled as a design value;
- equipment is entered as specs (dish size, power, thrust) and performance
  is computed from them, never typed in;
- each model is labelled Real, Projected or Notional (`core/docs/FIDELITY.md`);
- Core never reaches into the game (`node core/tools/check-core.mjs`).

How to run and test Core is in [core/README.md](../core/README.md).
