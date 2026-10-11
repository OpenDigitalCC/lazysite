package Lazysite::Manager::Csrf;

# The M-1 CSRF gate on write actions, moved out of lazysite-manager-api.pl by
# SM944 S34 as ruled 2026-10-11 ("Yes, as planned").
#
# Index
#   csrf_refusal  the gate: the refusal a request meets, or nothing
#
# csrf_refusal($method) never ends the request. It returns the refusal, and the
# script ends the request through its own _bail at the gate's old place - after
# the body read and the auth check, before the csrf-token mint and every later
# gate - so a module that loads this one is never exited by it. The moved lines
# are the script's but for two: each `_bail( {...} )` became `return {...}`
# (the gate's refusal, and the account check S34 (b) put first). `$method` stays
# the script's, passed in and read again by the POST-only refusal.
#
# The request context ($auth_user, $token_auth, $action, $body, %params and the
# body memo behind _json_body) is read from Lazysite::Manager::Common, which the
# script sets and nothing here assigns (t/lint/217). Outside a request the
# context's reset leaves nobody, and the gate refuses (t/unit/manager/205).

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util            qw(log_event);
use Lazysite::Auth::Session   qw(verify_csrf_token);
use Lazysite::Manager::Common qw(_json_body $auth_user $token_auth $action $body %params);

our @EXPORT_OK = qw(csrf_refusal);

# The refusal a request meets at the CSRF gate, or nothing when it passes.
sub csrf_refusal {
    my ($method) = @_;
    # SM944 S34 (b), ruled 2026-10-11 ("Yes, as planned"): THE GATE ASKS FOR AN
    # ACCOUNT FIRST. It exempts a token client, and the request context's reset
    # leaves one with nobody asking, so the gate run anywhere but after the auth
    # check passed a POST for nobody (tmp/sm944-s34-outside-probe.out). Inside a
    # request the auth check has refused an empty account on both channels before
    # this line, so no answer there changes.
    unless ( length $auth_user ) {
        return { ok => 0, kind => 'forbidden',
            error => 'A request is answered for a signed-in account, and no account is asking.' };
    }
    if ( $method eq 'POST' && !$token_auth ) {
        # Token can arrive via (in order of preference):
        #   - X-CSRF-Token header (HTTP_X_CSRF_TOKEN env var) - works for any
        #     body type including raw binary uploads (theme-upload).
        #   - csrf_token field in a JSON body - convenient for existing
        #     apiCall() patterns that send JSON.
        #   - csrf_token query-string parameter - last-resort fallback for
        #     sendBeacon() calls that cannot set headers.
        my $token  = $ENV{HTTP_X_CSRF_TOKEN} // '';
        my $source = $token ? 'header' : '';
        if ( !$token && $body ) {
            my $parsed = _json_body();
            if ( ref $parsed eq 'HASH' ) {
                $token  = $parsed->{csrf_token} // '';
                $source = 'body' if $token;
            }
        }
        if ( !$token ) {
            $token  = $params{csrf_token} // '';
            $source = 'query' if $token;
        }

        log_event( 'DEBUG', $action, 'CSRF check',
            method    => $method,
            user      => $auth_user,
            token_len => length($token),
            source    => $source || 'none',
            result    => $token ? 'has-token' : 'no-token' );

        my $valid = verify_csrf_token( $token, $auth_user );

        log_event( 'DEBUG', $action, 'CSRF verify',
            user   => $auth_user,
            result => $valid ? 'ok' : 'fail' );

        unless ($valid) {
            return { ok => 0, kind => 'forbidden', error => 'Invalid or missing CSRF token' };
        }
    }
    return;
}

1;
