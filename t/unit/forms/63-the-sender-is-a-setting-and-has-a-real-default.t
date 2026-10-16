#!/usr/bin/perl
# SM1109 (0.15.7 test plan, "Found while getting mail to send", U6): "The default
# sender webforms@localhost is refused by a real mail server ... the Form SMTP
# settings cannot change (the extension has no From field) ... Wanted: a
# site-level From on the Form SMTP extension (or site_url's host as the default),
# and the outbox naming the sender when RCPT fails." Ruled: "from default ok".
#
# The chain: the handler's from, the extension's From setting, no-reply@<host of
# site_url>, and only when site_url does not resolve the old webforms@localhost,
# with a log line saying so. A From setting is validated as one address when it
# is saved. A refused RCPT names the sender it was refused for.
use strict;
use warnings;
use Test::More;
use JSON::PP   ();
use File::Path qw(make_path);
use IPC::Open3 ();
use Symbol     qw(gensym);
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use Lazysite::Manager::Plugins ();
use File::Copy qw(copy);

my $root   = repo_root();
my $script = "$root/plugins/form-smtp.pl";
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

my $d = site_tempdir();
make_path("$d/lazysite/forms");
my $out  = "$d/mail.out";
my $mock = "$d/sendmail";
spit( $mock, "#!$^X\nopen my \$w, '>', '$out' or exit 1; local \$/; print {\$w} join(' ', \@ARGV), qq{\\n}, <STDIN>; close \$w;\n" );
chmod 0755, $mock;

sub site_conf { spit( "$d/lazysite/lazysite.conf", $_[0] ) }
sub smtp_conf { spit( "$d/lazysite/forms/smtp.conf", "method: sendmail\nsendmail_path: $mock\n" . ( $_[0] // '' ) ) }

# Sends one message; returns ( the From header, the stderr text, the reply ).
sub send_it {
    my (%cfg) = @_;
    unlink $out;
    local $ENV{DOCUMENT_ROOT} = $d;
    local $ENV{LAZYSITE_LOG_LEVEL} = 'DEBUG';
    delete local $ENV{REQUEST_SCHEME};
    delete local $ENV{SERVER_NAME};
    my $err = gensym;
    my $pid = IPC::Open3::open3( my $in, my $o, $err, $^X, $script, '--pipe' );
    print {$in} JSON::PP::encode_json( { config => { to => 'ada@example.net', %cfg }, form => { message => 'hello' } } );
    close $in;
    my $res  = do { local $/; <$o> };
    my $logs = do { local $/; <$err> };
    waitpid $pid, 0;
    my $r    = JSON::PP::decode_json( $res || '{}' );
    my $mail = slurp($out);
    my ($from) = $mail =~ /^From: (.*)$/m;
    return ( $from, $logs, $r, $mail );
}

subtest 'the extension offers a From address' => sub {
    my $desc = JSON::PP::decode_json( qx($^X \Q$script\E --describe) );
    my ($f) = grep { $_->{key} eq 'from' } @{ $desc->{config_schema} };
    ok( $f, 'the schema has a from field' );
    is( $f->{type}, 'email', '...of type email' );
};

subtest 'the chain' => sub {
    site_conf("site_url: https://www.example.net/\n");
    smtp_conf();
    my ( $from, $logs, $r, $mail ) = send_it();
    ok( $r->{ok}, 'sent' ) or diag( $r->{error} );
    is( $from, 'no-reply@www.example.net', 'no From set: no-reply@ the host of site_url' );
    like( $mail, qr/^-t -oi -f no-reply\@www\.example\.net$/m, '...and it is the envelope sender too' );
    unlike( $logs, qr/webforms/, '...with no fallback warning' );

    site_conf("site_url: http://shop.example.org:8080/path\n");
    ( $from ) = send_it();
    is( $from, 'no-reply@shop.example.org', 'the port and path are not part of the sender' );

    smtp_conf("from: ops\@example.org\n");
    ( $from ) = send_it();
    is( $from, 'ops@example.org', 'the extension\'s From setting wins over the site_url default' );

    ( $from ) = send_it( from => 'forms@example.org' );
    is( $from, 'forms@example.org', 'a handler\'s own from wins over the extension\'s' );

    ( $from ) = send_it( from => '' );
    is( $from, 'ops@example.org', 'an empty handler from is not a sender' );

    smtp_conf("from:    \n");
    site_conf("site_url: https://www.example.net/\n");
    ( $from ) = send_it();
    is( $from, 'no-reply@www.example.net', 'a blank From setting is not a sender either' );
};

subtest 'site_url that does not resolve keeps the old fallback and says so' => sub {
    smtp_conf();
    for my $case ( [ 'no site_url', "site_name: T\n" ], [ 'an unexpanded template', "site_url: \${REQUEST_SCHEME}://\${SERVER_NAME}\n" ] ) {
        site_conf( $case->[1] );
        my ( $from, $logs, $r ) = send_it();
        ok( $r->{ok}, "$case->[0]: still sent" );
        is( $from, 'webforms@localhost', '...as the old fallback' );
        like( $logs, qr/WARN.*site_url does not resolve/, '...and the log says why' );
    }
};

subtest 'a From setting is validated when it is saved' => sub {
    my $parent = site_tempdir();
    my $dr     = "$parent/public_html";
    make_path( "$dr/lazysite/forms", "$parent/plugins" );
    copy( $script, "$parent/plugins/form-smtp.pl" ) or die $!;
    chmod 0755, "$parent/plugins/form-smtp.pl";
    local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );
    $Lazysite::Manager::Plugins::DOCROOT = $dr;
    my $save = sub { Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/form-smtp.pl', {@_} ) };
    my $conf = "$dr/lazysite/forms/smtp.conf";

    my $r = $save->( from => 'ops@example.org' );
    ok( $r->{ok}, 'one address saves' ) or diag( $r->{error} // '' );
    like( slurp($conf), qr/^from: ops\@example\.org$/m, '...and is written' );
    for my $bad ( 'a@example.org, b@example.org', 'not an address', "x\@example.org\nbcc: y" ) {
        ( my $label = $bad ) =~ s/\n/\\n/g;
        $r = $save->( from => $bad );
        ok( !$r->{ok}, "'$label' is refused" );
        is( $r->{field} // '', 'from', '...naming the field' );
    }
    like( slurp($conf), qr/^from: ops\@example\.org$/m, 'the refused values changed nothing' );
    $r = $save->( from => '' );
    ok( $r->{ok}, 'an empty From saves (it means: use the default)' );
};

subtest 'a refused RCPT names the sender used' => sub {
    my $srv = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1 )
        or die "cannot listen: $!";
    my $port = $srv->sockport;
    my $pid  = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        local $SIG{ALRM} = sub { exit 0 };
        alarm 30;
        while ( my $c = $srv->accept ) {
            $c->autoflush(1);
            print {$c} "220 mock ready\r\n";
            while ( my $line = <$c> ) {
                $line =~ s/[\r\n]+\z//;
                if    ( $line =~ /^(?:EHLO|HELO)\b/i ) { print {$c} "250 mock\r\n" }
                elsif ( $line =~ /^RCPT/i )            { print {$c} "550 5.7.1 relay denied\r\n" }
                elsif ( $line =~ /^QUIT/i )            { print {$c} "221 bye\r\n"; last }
                else                                   { print {$c} "250 OK\r\n" }
            }
            close $c;
        }
        exit 0;
    }
    close $srv;
    site_conf("site_url: https://www.example.net/\n");
    spit( "$d/lazysite/forms/smtp.conf", "method: smtp\nhost: 127.0.0.1\nport: $port\ntls: false\n" );
    my ( undef, undef, $r ) = send_it();
    ok( !$r->{ok}, 'the send fails' );
    like( $r->{error}, qr/\ARCPT TO refused for ada\@example\.net sending as no-reply\@www\.example\.net: 550 5\.7\.1 relay denied\z/,
        'and says who it was to, who it was from, and what the server said' )
        or diag( $r->{error} // '' );
    kill 'TERM', $pid;
    waitpid $pid, 0;
};

done_testing;
