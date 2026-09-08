#!/usr/bin/perl
# SM785: YOU MAY NOT OVERWRITE A STORE YOU COULD NOT READ.
#
# Every settings writer is a read-modify-write: read the whole hash, change one
# account's entry, write the whole hash back. `read_settings` answers `{}` for
# a store it could not open - so the modify step built a hash holding ONE
# account, and the write step made that true. Every other account's display
# name, comment, email, expiry, token TTL and start page: gone. And a rename
# needs no permission on the TARGET file, only on its directory, so an
# unreadable store was not even an obstacle.
#
# It fired on an ordinary request. Token verification stamps "last used"
# through touch_credential, which is a read-modify-write of this store, so any
# API call against a site whose settings file had lost its permissions emptied
# the file.
#
# This was found by a SM778 test, not by review: with the store unreadable, the
# display-name map came back EMPTY with readable:1 - because the failing read
# had already been followed by a write that made the store genuinely empty.
#
# It is the four-states rule (SM784) at its most expensive. `{}` meant "could
# not tell" and a writer read it as "there is nothing here". The reader cannot
# fix that alone - there is nowhere in `{}` to put the difference - so the
# writer asks whether the read that produced its argument succeeded.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Auth::Settings;

plan skip_all => 'root reads every file; this needs an unprivileged user' if $> == 0;

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);
my $file = "$auth/user-settings.json";

my $POPULATED = '{"alice":{"display_name":"Alice","email":"a@example.test"},'
    . '"bob":{"display_name":"Bob","start_page":"/team"}}';
sub put { open my $fh, '>', $file or die "$file: $!"; print {$fh} $POPULATED; close $fh }
sub now_on_disk { open my $fh, '<', $file or return "UNREADABLE"; local $/; <$fh> }

$Lazysite::Auth::Settings::AUTH_DIR = $auth;
put();

my @log;
sub with_log {
    my ($code) = @_;
    @log = ();
    no warnings 'redefine';
    # The refusal logs from THIS module, which imported log_event into its own
    # namespace - overriding only Util's copy catches cannot_read and misses it.
    local *Lazysite::Util::log_event           = sub { push @log, [@_] };
    local *Lazysite::Auth::Settings::log_event = sub { push @log, [@_] };
    return $code->();
}

subtest 'the baseline: a readable store is written normally' => sub {
    Lazysite::Auth::Settings::_settings_cache_clear();
    ok( Lazysite::Auth::Settings::touch_credential('alice'),
        'the last-used stamp lands when the store can be read' );
    my $after = Lazysite::Auth::Settings::read_settings();
    is( $after->{bob}{display_name}, 'Bob', "and bob's settings are still there" );
    ok( $after->{alice}{cred_used_at}, 'while alice got her stamp' );
};

subtest 'an unreadable store is left exactly as it was' => sub {
    put();
    my $before = now_on_disk();
    chmod 0000, $file;
    Lazysite::Auth::Settings::_settings_cache_clear();
    ok( !-r $file, 'the fixture holds: the file cannot be read' )
        or do { chmod 0644, $file; plan skip_all => 'this filesystem ignores the file mode' };

    # This is the call an ordinary API request makes. It must not succeed by
    # replacing the store with the one account it was stamping.
    my $ok = with_log( sub { Lazysite::Auth::Settings::touch_credential('alice') } );
    chmod 0644, $file;

    is( $ok, 0, 'the stamp reports that it did not happen' );
    is( now_on_disk(), $before,
        'AND THE STORE IS BYTE-FOR-BYTE WHAT IT WAS - no account lost its settings' );
    ok( ( grep { $_->[0] eq 'WARN' && $_->[2] =~ /refusing to write/ } @log ),
        'the refusal is logged, so an operator learns the permissions are wrong' )
        or diag explain \@log;
};

subtest 'the refusal names the file and says what it prevented' => sub {
    put();
    chmod 0000, $file;
    Lazysite::Auth::Settings::_settings_cache_clear();
    Lazysite::Auth::Settings::read_settings();    # the failing read this write follows
    my $err = do {
        local $@;
        eval { Lazysite::Auth::Settings::write_settings( { alice => { x => 1 } } ) };
        $@;
    };
    chmod 0644, $file;
    like( $err, qr/\Q$file\E/,     'the message names the file' );
    like( $err, qr/every account/, 'and what the write would have done' );
    like( $err, qr/permissions/,   'and the thing to fix' );
};

subtest 'a store that is simply ABSENT is still written - a first write must land' => sub {
    my $fresh = site_tempdir();
    make_path("$fresh/lazysite/auth");
    local $Lazysite::Auth::Settings::AUTH_DIR = "$fresh/lazysite/auth";
    Lazysite::Auth::Settings::_settings_cache_clear();
    Lazysite::Auth::Settings::read_settings();    # ENOENT: an ordinary state
    ok( Lazysite::Auth::Settings::settings_readable(),
        'an absent store reads as readable - there is nothing it could not tell us' );
    ok( eval { Lazysite::Auth::Settings::write_settings( { alice => { display_name => 'Alice' } } ); 1 },
        'so the first write is allowed' ) or diag $@;
    is( Lazysite::Auth::Settings::read_settings()->{alice}{display_name},
        'Alice', 'and it landed' );
};

END { chmod 0644, $file if defined $file && -e $file }

done_testing;
