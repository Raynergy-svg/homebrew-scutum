class IrondomeSentinel < Formula
  desc "macOS LaunchAgent + local defensive pipeline"
  homepage "https://github.com/Raynergy-svg/Scutum"
  url "https://github.com/Raynergy-svg/Scutum/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7a136c28ebd8ee40f5015b17c23483e3d69a3a7cfc72de727edd39119be5be3d"
  revision 1
  license "MIT"

  depends_on "python"

  def install
    libexec.install Dir["*"]

    # Primary command
    (bin/"irondome-sentinel").write_env_script pkgshare/"scripts/irondome-sentinel.py", {
      "PYTHONUNBUFFERED" => "1",
    }

    # Alias command
    bin.install_symlink "irondome-sentinel" => "irondome"

    # Ship templates/scripts for local setup.
    pkgshare.install libexec/"launchd"
    pkgshare.install libexec/"scripts"
    pkgshare.install libexec/"docker-compose.yaml" if (libexec/"docker-compose.yaml").exist?
  end

  def caveats
    <<~EOS
      Irondome-Sentinel installs scripts and LaunchAgent templates.

      Next steps:
        1) Configure Messages permissions (Automation) and Full Disk Access for the Python used by Homebrew.
        2) Install the LaunchAgent:

           zsh "#{opt_pkgshare}/scripts/irondome-sentinel-install-launchagent.zsh"

      Optional Buddy (pipeline loop without iMessage):

           zsh "#{opt_pkgshare}/scripts/irondome-buddy-install-launchagent.zsh"

      Config:
        ~/Library/Application Support/IronDome/config.json
    EOS
  end

  test do
    assert_match "Iron Dome Sentinel", shell_output("#{bin}/irondome-sentinel --help")
  end
end
