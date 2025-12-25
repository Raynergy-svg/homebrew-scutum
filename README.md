# Raynergy-svg/homebrew-scutum

Homebrew tap for Scutum.

## Install

```zsh
brew tap Raynergy-svg/scutum
brew install irondome-sentinel

# Recommended onboarding (starts Ollama + creates the 'sentinel' model automatically)
irondome-sentinel-setup
```

## Clean reinstall test (tap)

Dry run:

```zsh
zsh ~/.continue/scripts/brew-reinstall-test.zsh
```

Actually run it:

```zsh
zsh ~/.continue/scripts/brew-reinstall-test.zsh --yes
```

## Notes

- The formula (`Formula/irondome-sentinel.rb`) installs from the GitHub tag tarball.

## Audit (optional)

Homebrew no longer allows `brew audit` to be called with a local file path. Audit by formula name after tapping:

```zsh
brew audit --strict --online --formula irondome-sentinel
```

Bundler may print a funding notice ("Run `bundle fund`"); it’s informational and not an error.
