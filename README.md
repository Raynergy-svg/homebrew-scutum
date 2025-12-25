# Raynergy-svg/homebrew-scutum

Homebrew tap for Scutum.

## Install

```zsh
brew tap Raynergy-svg/scutum
brew install irondome-sentinel

# If you plan to use router_model=ollama, start the daemon
brew services start ollama

# Optional (recommended): create the local model used by Sentinel
ollama create sentinel -f ~/.continue/ollama-models/sentinel/Modelfile

# Recommended onboarding
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
