package proxy

// slider_validate_test.go — validates the v2 slider port (rankSliderCandidates)
// against a REAL VK slider puzzle captured from amurcanov's working solver.
//
// Capture step (in the amurcanov harness repo):
//   AB_NO_HEADER_ORDER=1 DUMP_SLIDER=1 VK_LINK=<id> ./amurcanov-iptest.macos \
//       -test.run TestIPReputation -test.v
//   → VK serves a slider, amurcanov's v2 solver cracks it (log: "slider attempt
//     1 (guess #N)" = the winning index), and DUMP_SLIDER writes the same
//     puzzle to /tmp/slider_puzzle.json.
//
// Then here:
//   go test -run TestSliderPortAgainstRealPuzzle -v ./pkg/proxy/
//   → our ported ranking runs on the SAME puzzle. Our #1 candidate.Index should
//     equal amurcanov's winning index N (same algorithm ⇒ same top pick),
//     proving the port is a faithful transcription.

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSliderPortAgainstRealPuzzle(t *testing.T) {
	path := os.Getenv("SLIDER_PUZZLE")
	if path == "" {
		// Committed fixture: a real VK slider (grid 5x5, 49 candidates) that
		// amurcanov's v2 solver accepted on attempt 1 with guess #24.
		path = "testdata/slider_puzzle.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read puzzle fixture %s: %v", path, err)
	}
	var dump struct {
		Image string `json:"image"`
		Steps []int  `json:"steps"`
	}
	if err := json.Unmarshal(data, &dump); err != nil {
		t.Fatalf("parse dump: %v", err)
	}

	size, swaps, attempts, err := parseSliderSteps(dump.Steps)
	if err != nil {
		t.Fatalf("parseSliderSteps: %v", err)
	}
	img, err := decodeSliderImage(dump.Image)
	if err != nil {
		t.Fatalf("decodeSliderImage: %v", err)
	}

	cands, err := rankSliderCandidates(img, size, swaps)
	if err != nil {
		t.Fatalf("rankSliderCandidates: %v", err)
	}

	t.Logf("puzzle: grid=%d swaps=%d attempts=%d image=%dx%d candidates=%d",
		size, len(swaps)/2, attempts, img.Bounds().Dx(), img.Bounds().Dy(), len(cands))
	top := 6
	if top > len(cands) {
		top = len(cands)
	}
	for i := 0; i < top; i++ {
		t.Logf("  our rank %d: index=%d consensus=%d", i+1, cands[i].Index, cands[i].Score)
	}
	t.Logf("==> OUR #1 candidate index = %d", cands[0].Index)

	// Regression assert: our ported 3-metric consensus must pick the SAME
	// answer amurcanov's v2 solver did (guess #24, accepted by VK on attempt 1).
	const wantTopIndex = 24
	if cands[0].Index != wantTopIndex {
		t.Errorf("ported ranking regressed: our #1 = index %d, want %d (amurcanov's accepted answer)", cands[0].Index, wantTopIndex)
	}
}
