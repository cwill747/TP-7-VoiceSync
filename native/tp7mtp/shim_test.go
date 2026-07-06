package main

import (
	"testing"
	"time"
)

func TestLocalizeWallClock(t *testing.T) {
	t.Run("zero time is left untouched", func(t *testing.T) {
		got := localizeWallClock(time.Time{})
		if !got.IsZero() {
			t.Fatalf("expected zero time, got %v", got)
		}
	})

	t.Run("bare wall-clock time (decoded as UTC) is reinterpreted in the local zone", func(t *testing.T) {
		// This is what go-mtpfs's decodeTime produces for a device timestamp
		// with no zone offset (e.g. the TP-7's "20260706T080000"): the right
		// Y/M/D h:m:s fields, but mislabeled with time.UTC.
		wallClock := time.Date(2026, 7, 6, 8, 0, 0, 0, time.UTC)

		got := localizeWallClock(wallClock)

		if got.Location() != time.Local {
			t.Fatalf("expected Local location, got %v", got.Location())
		}
		if y, m, d := got.Date(); y != 2026 || m != time.July || d != 6 {
			t.Fatalf("expected date 2026-07-06, got %d-%02d-%02d", y, m, d)
		}
		if h, mi, s := got.Clock(); h != 8 || mi != 0 || s != 0 {
			t.Fatalf("expected clock 08:00:00, got %02d:%02d:%02d", h, mi, s)
		}
	})

	t.Run("timestamp with an explicit numeric offset is left untouched", func(t *testing.T) {
		// go-mtpfs's numTZ fallback format parses these into a fixed-offset
		// Location (not the time.UTC singleton), so the instant is already
		// unambiguous and must not be shifted again.
		offset := time.FixedZone("-0700", -7*60*60)
		withOffset := time.Date(2026, 7, 6, 8, 0, 0, 0, offset)

		got := localizeWallClock(withOffset)

		if !got.Equal(withOffset) || got.Location() != offset {
			t.Fatalf("expected unchanged %v, got %v", withOffset, got)
		}
	})
}
