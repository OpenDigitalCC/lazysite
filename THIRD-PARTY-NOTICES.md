# Third-party notices

lazysite bundles the following third-party components. Everything else in
this distribution is original work of Open Digital CC (see LICENSE).
Runtime Perl dependencies are NOT bundled - they are installed from the
operating system's package repository and carry their own licences (see
docs/reference/host-dependencies.md and the release SBOM).

## CodeMirror 5.65.16

Files: `starter/manager/assets/cm/*` (minified; upstream licence headers
are removed by minification, so the licence is reproduced here as the MIT
licence requires).

Source: https://codemirror.net/5/ - Copyright (C) 2017 by Marijn Haverbeke
<marijnh@gmail.com> and others.

Licence: MIT

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
    BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
    ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## qrcode-generator 1.4.4

File: `starter/manager/assets/qrcode.js` (unminified; the upstream MIT
licence header is retained in the file). Used to render the 2FA
enrolment QR code in the browser from the account's `otpauth://` URI -
pure computation (no DOM, no `eval`, no network); lazysite reads the
module matrix via `qr.isDark()` and draws the SVG itself.

Source: https://github.com/kazuhikoarase/qrcode-generator - Copyright
(c) 2009 Kazuhiko Arase. ('QR Code' is a registered trademark of DENSO
WAVE INCORPORATED.)

Licence: MIT

    Permission is hereby granted, free of charge, to any person obtaining
    a copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:

    The above copyright notice and this permission notice shall be
    included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
    NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
    BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
    ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
    CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
