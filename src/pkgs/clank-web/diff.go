package main

// Per-file view of result/diff.patch (a git diff with untracked files).

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

type File struct {
	Path    string `json:"path"`
	Status  string `json:"status"` // modified, added, deleted, renamed
	Added   int    `json:"added"`
	Removed int    `json:"removed"`
	Binary  bool   `json:"binary,omitempty"`
	Patch   string `json:"patch,omitempty"`
}

func readFiles(dir string) []File {
	files := parsePatch(filepath.Join(dir, "result", "diff.patch"))
	for i := range files {
		files[i].Patch = ""
	}
	return files
}

func parsePatch(path string) []File {
	f, err := os.Open(path)
	if err != nil {
		return []File{}
	}
	defer f.Close()
	files := []File{}
	var cur *File
	var body strings.Builder
	done := func() {
		if cur != nil {
			cur.Patch = body.String()
			files = append(files, *cur)
		}
		body.Reset()
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	inHunk := false
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "diff --git ") {
			done()
			cur = &File{Status: "modified", Path: gitPathB(line)}
			inHunk = false
			continue
		}
		if cur == nil {
			continue
		}
		switch {
		case !inHunk && strings.HasPrefix(line, "new file mode"):
			cur.Status = "added"
		case !inHunk && strings.HasPrefix(line, "deleted file mode"):
			cur.Status = "deleted"
		case !inHunk && strings.HasPrefix(line, "rename to "):
			cur.Status, cur.Path = "renamed", strings.TrimPrefix(line, "rename to ")
		case !inHunk && strings.HasPrefix(line, "Binary files "):
			cur.Binary = true
		case !inHunk && strings.HasPrefix(line, "+++ "):
			if p, ok := strings.CutPrefix(line, "+++ b/"); ok {
				cur.Path = p
			}
		case !inHunk && strings.HasPrefix(line, "--- "):
			if p, ok := strings.CutPrefix(line, "--- a/"); ok && cur.Status == "deleted" {
				cur.Path = p
			}
		case strings.HasPrefix(line, "@@"):
			inHunk = true
			body.WriteString(line + "\n")
		case inHunk:
			body.WriteString(line + "\n")
			if strings.HasPrefix(line, "+") {
				cur.Added++
			} else if strings.HasPrefix(line, "-") {
				cur.Removed++
			}
		}
	}
	done()
	return files
}

// gitPathB takes the b/ path from "diff --git a/x b/x" (paths without spaces;
// the +++ or rename lines correct it otherwise).
func gitPathB(line string) string {
	rest := strings.TrimPrefix(line, "diff --git ")
	if i := strings.LastIndex(rest, " b/"); i >= 0 {
		return rest[i+3:]
	}
	return rest
}
