// Copyright 2022 The Gitea Authors. All rights reserved.
// SPDX-License-Identifier: MIT

//go:build !windows

package log

import (
	"os"

	"github.com/mattn/go-isatty"
)

func init() {
	// when gitea's console output is not a terminal (for example a service manager writing it to a log
	// file), the output can not be colorized, otherwise the log fills with escape sequences like
	// "#033[0m#033[32mcmd/web.go:102:#033[32m". this file covers non-windows platforms.
	CanColorStdout = isatty.IsTerminal(os.Stdout.Fd())
	CanColorStderr = isatty.IsTerminal(os.Stderr.Fd())
}
