#!/usr/bin/perl
# SM831: you deprecate a spelling in order to retire it, and the retirement
# question is "is anyone still calling the old one".
#
# Measured in the field on 0.13.11: four paired calls - plugin-action,
# extension-action, plugin-save, extension-save - and ALL FOUR audited as
# `plugin-*`. The string "extension" appeared nowhere in 10,772 bytes of audit
# across fifty entries. So SM817 shipped the compatibility and lost the
# instrument that says when compatibility can end.
#
# Normalising at one point is right and stays - it is why the two spellings
# cannot drift. Throwing the original away before anything recorded it was the
# mistake, and $action_as_sent already existed for the deprecation INFO.
#
# A FLAG, NOT A SECOND ACTION NAME. Recording `extension-save` in the action
# field would split one act across two spellings for everything that counts or
# filters audit lines, including readers already deployed, which would silently
# stop matching. The canonical name stays and one boolean answers the question.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use MIME::Base64 qw(encode_base64);
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps revoke_caps site_tempdir);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{LAZYSITE_USERS_TOOL} = $utool;
    $ENV{REQUEST_METHOD}      = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH}      = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $d = site_tempdir();    # lint 118: not a bare tempdir
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "control_api_enabled: true\nplugins:\n  - plugins/briefs.pl\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1,"assignable":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;

uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
plan skip_all => 'no partner token' unless $tok;
grant_caps( $d, 'partner', 'api', 'manage_config' );

my $audit = "$d/lazysite/logs/audit.log";

sub audit_lines {
    open my $fh, '<', $audit or return ();
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

sub call {
    my ($qs) = @_;
    return mapi( $d, QUERY_STRING => $qs, REQUEST_METHOD => 'POST',
        body => '{}', HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
}

# --- the error text names what the caller typed ------------------------------
{
    my $r = call('action=extension-nosuchthing');
    ok( !$r->{ok}, 'an unknown action in the new spelling is refused' );
    like( $r->{error}, qr/extension-nosuchthing/,
        'and the refusal names the verb the caller actually typed' )
        or diag "error was: " . ( $r->{error} // '(none)' );
    unlike( $r->{error}, qr/plugin-nosuchthing/,
        '...rather than a verb that appears nowhere in their code' );
}

# --- the audit carries the spelling ------------------------------------------
# ASSERTED FROM THE SOURCE, and the reason is a gap worth naming rather than a
# preference. Every plugin-*/extension-* action is COOKIE-ONLY - the same wall
# the field hit when it could not quote the deprecation INFO - so no paired
# action is reachable over the token channel these tests can drive, and the
# suite has no fixture that mints a manager session. The behavioural half above
# is real; this half is structural until such a fixture exists.
#
# What is asserted is the WIRING, which is where this defect actually lived: the
# original spelling existed all along and simply never reached the recorder.
{
    open my $fh, '<:utf8', $mapi or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;

    like( $src, qr/my \$deprecated_spelling = \( \$action_as_sent =~/,
        'the flag is derived from the spelling as sent' );

    like( $src, qr/sub _audit_detail/, 'and there is one place that applies it' );

    # EVERY AUDIT CALL THAT RECORDS A VARIABLE ACTION must carry it. One of the
    # two carrying it would be worse than neither: half a record answering the
    # retirement question is a wrong answer rather than a missing one.
    #
    # Matched to the next semicolon, not to `);` - an earlier draft of this
    # assertion used `);` and silently skipped the success-path call, which ends
    # `) unless $skip_audit;`. It then reported 1 of 2 and was measuring the
    # wrong two sites entirely.
    my @calls = ( $src =~ /audit_log\((.*?);/gs );
    my ( @variable, @literal );
    for my $c (@calls) {
        # The second argument is the action. A literal one cannot be a
        # plugin-*/extension-* call: the only such site records the 'audit'
        # action's own refusal.
        # The ACTION is the second argument; whoever the first names, a quoted
        # literal there is a fixed action - N13-04's audit-trail edges pass $who.
        if ( $c =~ /\A\s*[^,]+,\s*'/ ) { push @literal, $c }
        else                                 { push @variable, $c }
    }
    cmp_ok( scalar @variable, '>=', 2, 'found the audit calls that record a variable action' );
    is( scalar( grep { /_audit_detail\(/ } @variable ), scalar @variable,
        'every audit call recording a variable action carries the spelling flag' )
        or diag 'a call site records an action without saying which spelling asked for it';
    is( scalar( grep { /_audit_detail\(/ } @literal ), 0,
        'and the fixed-action refusal does not pretend to carry one' );

    # The canonical name is what goes in the action field. A second action name
    # would split one act across two spellings for every deployed reader.
    unlike( $src, qr/audit_log\(\s*\$auth_user,\s*\$action_as_sent/,
        'the action field keeps the canonical name, not the spelling as sent' );
}

done_testing();
