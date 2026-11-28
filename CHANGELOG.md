# Changelog

Releases from v1.14.0 on are written here by release-please from the commit titles. Earlier releases are in the README's Version History and on the [GitHub Releases](https://github.com/willardcsoriano/debian-intel-macbook-post-install/releases) page.

## [1.16.1](https://github.com/willardcsoriano/debian-intel-macbook-post-install/compare/v1.16.0...v1.16.1) (2026-11-28)


### Bug Fixes

* **power:** run sleep hooks from units systemd actually starts ([adc75a6](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/adc75a6a46fa313b2e86f95b111ab7d25a2de46a)), closes [#78](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/78)
* **setup:** adopt old launcher copies after their package changed ([40eadd5](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/40eadd50520d41ab9cdaf2860f292eefdc2854cb)), closes [#79](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/79)
* **setup:** keep App Finder launcher copies in step with their packages ([ad6de6f](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/ad6de6fda2ee300826341ac15333a062a1c5d910)), closes [#79](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/79)
* **setup:** stop rewriting power and polkit config on every run ([9a067da](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/9a067da91423db15c2c375e3b7274ccf6cb7c333)), closes [#80](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/80)
* **setup:** word skips as done and count already-installed packages ([03c38c1](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/03c38c158d4137d34c32133c7a699a0a8e7af641))

## [1.16.0](https://github.com/willardcsoriano/debian-intel-macbook-post-install/compare/v1.15.0...v1.16.0) (2026-11-23)


### Features

* **wifi:** add fix-wifi and the wifi-watchdog user service ([d1b6b3f](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/d1b6b3fa69237f5d7a19a340d4183b9c4dc7aada)), closes [#75](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/75)

## [1.15.0](https://github.com/willardcsoriano/debian-intel-macbook-post-install/compare/v1.14.0...v1.15.0) (2026-11-22)


### Features

* **setup:** replace Alarm Clock with GNOME Clocks ([726a004](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/726a004d610337f8e10867319bdf964af56eb56d)), closes [#70](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/70)


### Bug Fixes

* **setup:** write the automatic updates switch instead of trusting dpkg-reconfigure ([9ff721a](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/9ff721a9f67b6508f97d527743c237b9571bbb7a)), closes [#41](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/41)

## [1.14.0](https://github.com/willardcsoriano/debian-intel-macbook-post-install/compare/v1.13.0...v1.14.0) (2026-11-20)


### Features

* **setup:** install an alarm and timer app the App Finder can find ([f1a92b9](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/f1a92b94d25b85ca66958fc632169c80e98ac8fa)), closes [#63](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/63)


### Bug Fixes

* **power:** keep the user session unfrozen during sleep ([63e4f21](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/63e4f21b5aec416381cb7e33ac0aa94dfce44d4e)), closes [#65](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/65)
* **setup:** write per-user launcher copies safely and report failures ([18731ef](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/18731efd3469e524e41360a2b06dfc9a1a469170)), closes [#63](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/63)
* **themes:** point dock icons at the launcher the app menu uses ([0df1a38](https://github.com/willardcsoriano/debian-intel-macbook-post-install/commit/0df1a3862b3150211d1ac06b9dd7ffe45a231c7a)), closes [#64](https://github.com/willardcsoriano/debian-intel-macbook-post-install/issues/64)
