function pct(covered, total) { return total ? 100 * covered / total : 100 }

function add(section, path, rest) {
  count[section]++
  rowPath[section, count[section]] = path
  rowRest[section, count[section]] = rest
}

function lineCells(path) {
  return sprintf("(covered %d/%d -> %d/%d)", bCov[path], bTot[path], aCov[path], aTot[path])
}

function branchCells(path) {
  return sprintf("(covered %d/%d -> %d/%d)", bBrCov[path], bBrTot[path], aBrCov[path], aBrTot[path])
}

function checkFile(path,    beforeMiss, afterMiss, beforeBranch, afterBranch, rose) {
  beforeMiss = bTot[path] - bCov[path]
  afterMiss = aTot[path] - aCov[path]
  beforeBranch = bBrTot[path] - bBrCov[path]
  afterBranch = aBrTot[path] - aBrCov[path]
  if (afterMiss > beforeMiss) {
    add("fail", path, sprintf("uncovered %d -> %d %s", beforeMiss, afterMiss, lineCells(path)))
    rose = 1
  }
  if (afterBranch > beforeBranch) {
    add("fail", path, sprintf("branches uncovered %d -> %d %s", beforeBranch, afterBranch, branchCells(path)))
    rose = 1
  }
  if (rose && kind[path] == "bash") bashRose = 1
  if (rose) return
  if (pct(aCov[path], aTot[path]) < pct(bCov[path], bTot[path]) - limit)
    add("drop", path, sprintf("%.2f%% -> %.2f%% %s", pct(bCov[path], bTot[path]), pct(aCov[path], aTot[path]), lineCells(path)))
}

function printSection(section, heading,    row, width) {
  if (!count[section]) return
  print heading
  for (row = 1; row <= count[section]; row++)
    if (length(rowPath[section, row]) > width) width = length(rowPath[section, row])
  for (row = 1; row <= count[section]; row++)
    printf "  %-*s  %s\n", width, rowPath[section, row], rowRest[section, row]
}

function checkTotal() {
  printf "total bash line coverage: %.2f%% (%d/%d) -> %.2f%% (%d/%d)\n", pct(sumBeforeCov, sumBeforeTot), sumBeforeCov, sumBeforeTot, pct(sumAfterCov, sumAfterTot), sumAfterCov, sumAfterTot
  if (sumAfterCov * sumBeforeTot >= sumBeforeCov * sumAfterTot) return
  if (bashRose) {
    print "total bash line coverage fell, already reported through the files below"
    return
  }
  print "FAIL: total bash line coverage fell with no per-file rise in uncovered lines"
  failed = 1
}

function collect(side,    path) {
  path = $3
  kind[path] = $2
  if (side == "B") {
    bCov[path] = $4; bTot[path] = $5; bBrCov[path] = $6; bBrTot[path] = $7
    hasBefore[path] = 1; beforeOrder[++beforeCount] = path
    if ($2 == "bash") { sumBeforeCov += $4; sumBeforeTot += $5 }
  } else {
    aCov[path] = $4; aTot[path] = $5; aBrCov[path] = $6; aBrTot[path] = $7
    hasAfter[path] = 1; afterOrder[++afterCount] = path
    if ($2 == "bash") { sumAfterCov += $4; sumAfterTot += $5 }
  }
}

BEGIN { FS = "\t"; limit = 0.5 }

{ collect($1) }

END {
  for (i = 1; i <= afterCount; i++) {
    path = afterOrder[i]
    if (path in hasBefore) checkFile(path)
    else add("new", path, sprintf("uncovered %d (covered %d/%d)", aTot[path] - aCov[path], aCov[path], aTot[path]))
  }
  for (i = 1; i <= beforeCount; i++) {
    path = beforeOrder[i]
    if (!(path in hasAfter)) add("gone", path, sprintf("uncovered %d (covered %d/%d)", bTot[path] - bCov[path], bCov[path], bTot[path]))
  }
  if (count["fail"]) failed = 1
  checkTotal()
  printSection("fail", "FAIL: uncovered counts rose")
  printSection("drop", "INFO: percent fell more than 0.5 points because line totals changed, uncovered counts did not rise")
  printSection("new", "INFO: new files")
  printSection("gone", "INFO: removed files")
  exit failed
}
