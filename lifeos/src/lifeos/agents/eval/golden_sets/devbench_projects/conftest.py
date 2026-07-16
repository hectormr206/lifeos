# Safety net: the mini-project suites below are RED BY DESIGN (the devbench
# role has candidate models fix them in a temp copy). Never collect them when
# pytest sweeps this tree; the harness runs each copied project explicitly
# with `python -I -m pytest` from inside the copy (this conftest is NOT
# copied — only the project dir itself is).
collect_ignore_glob = ["db-*"]
