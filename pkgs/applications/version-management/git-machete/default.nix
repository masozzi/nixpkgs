{ lib
, buildPythonApplication
, pytest-mock
, pytestCheckHook
, fetchFromGitHub
, installShellFiles
, git
, nix-update-script
, testers
, git-machete
}:

buildPythonApplication rec {
  pname = "git-machete";
  version = "3.13.2";

  src = fetchFromGitHub {
    owner = "virtuslab";
    repo = pname;
    rev = "v${version}";
    sha256 = "sha256-K9oJvvESHWCJFSgqycA7N4cG7WbTDwXZExnXUs4Qlp8=";
  };

  nativeBuildInputs = [ installShellFiles ];

  checkInputs = [ git pytest-mock pytestCheckHook ];

  postInstall = ''
    installShellCompletion --bash --name git-machete completion/git-machete.completion.bash
    installShellCompletion --zsh --name _git-machete completion/git-machete.completion.zsh
    installShellCompletion --fish completion/git-machete.fish
  '';

  postInstallCheck = ''
    test "$($out/bin/git-machete version)" = "git-machete version ${version}"
  '';

  passthru = {
    updateScript = nix-update-script { };
  };

  meta = with lib; {
    homepage = "https://github.com/VirtusLab/git-machete";
    description = "Git repository organizer and rebase/merge workflow automation tool";
    license = licenses.mit;
    maintainers = with maintainers; [ blitz ];
  };
}
