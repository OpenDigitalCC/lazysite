#!/usr/bin/perl
# SM905 U5: the three upload_* keys the form handler reads get a writer.
#
# The form handler refuses every upload until a form's own conf carries at least
# one of upload_max_kb, upload_max_files or upload_accept - so that a form never
# accepts files by accident. The only writer was form-targets-save, which writes
# `targets:` and nothing else. So an agent could create the handler, bind the
# form, render the file input, and then watch every submission refused with "this
# form does not accept file uploads", with no action to fix it. The 0.15.0 edge
# walk confirmed it from outside and hand-wrote the conf over WebDAV to finish.
#
# AND SM913's QUESTION, ANSWERED: a quarantined submission gets no
# acknowledgement. Holding a suspect submission back from the notification bell
# and then WRITING TO THE ADDRESS IT SUPPLIED is not consistent - the second is
# louder than the first, and it is the open-relay shape the caps bound.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Handlers ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub a_site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/forms");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: jsonl\n    type: file\n    path: lazysite/forms/submissions\n" );
    spit( "$d/lazysite/forms/contact.conf", $conf // "targets:\n  - handler: jsonl\n" );
    $Lazysite::Handlers::DOCROOT = $d;
    return $d;
}

subtest 'turning uploads on writes the keys the form handler reads' => sub {
    my $d = a_site();
    my $r = Lazysite::Handlers::action_form_uploads_save( 'contact', 1,
        { max_kb => 2048, max_files => 3, accept => 'png, jpg' } );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;

    my $conf = slurp("$d/lazysite/forms/contact.conf") // '';
    like( $conf, qr/^upload_max_kb: 2048$/m,   'the size limit is written' );
    like( $conf, qr/^upload_max_files: 3$/m,   'the count limit is written' );
    like( $conf, qr/^upload_accept: png, jpg$/m, 'and the extension list' );
    like( $conf, qr/\Atargets:\n  - handler: jsonl\n/,
        'and the binding it already had is still first' )
        or diag('Rewriting a conf must not lose what it did not come to change.');
};

subtest 'on with nothing else gives the handler its own defaults' => sub {
    my $d = a_site();
    my $r = Lazysite::Handlers::action_form_uploads_save( 'contact', 'true', {} );
    ok( $r->{ok}, 'accepted' );
    my $conf = slurp("$d/lazysite/forms/contact.conf") // '';
    like( $conf, qr/^upload_max_kb: 5120$/m,  'the default size' );
    like( $conf, qr/^upload_max_files: 5$/m,  'the default count' );
    unlike( $conf, qr/upload_accept/,
        'and no extension list, which means any type - not an empty allowlist' )
        or diag( 'An empty accept list that matched nothing would refuse every '
            . 'upload while reading as configured.' );
};

subtest 'a JSON boolean is a boolean' => sub {
    # handler-save refuses a JSON `true` for attach_files and wants the string,
    # which the edge walk lost time to. A new action does not repeat it.
    for my $on ( 1, 'true', 'on', 'yes', \1 ) {
        my $d = a_site();
        my $r = Lazysite::Handlers::action_form_uploads_save( 'contact', ( ref $on ? $$on : $on ), {} );
        ok( $r->{ok} && $r->{uploads}, "'" . ( ref $on ? 'JSON true' : $on ) . "' means on" );
    }
    for my $off ( 0, 'false', '', undef ) {
        my $d = a_site("targets:\n  - handler: jsonl\nupload_max_kb: 100\n");
        my $r = Lazysite::Handlers::action_form_uploads_save( 'contact', $off, {} );
        ok( $r->{ok} && !$r->{uploads},
            "'" . ( defined $off ? $off : 'absent' ) . "' means off" );
        unlike( slurp("$d/lazysite/forms/contact.conf") // '', qr/upload_/,
            'and every upload key is removed, not just the ones named' )
            or diag( 'A stale key the reader still honours is uploads still on '
                . 'after being turned off.' );
    }
};

subtest 'the refusals name the field and the vocabulary' => sub {
    my $d = a_site();
    for my $bad ( 'lots', '-1', '2.5', '0' ) {
        my $r = Lazysite::Handlers::action_form_uploads_save( 'contact', 1, { max_kb => $bad } );
        ok( !$r->{ok}, "max_kb '$bad' refused" );
        is( $r->{field}, 'max_kb', 'naming the field' );
    }

    # THE ONE WORTH THE MOST. `accept:` in the page grammar is a MEDIA TYPE and
    # `upload_accept` here is an EXTENSION LIST - one word, two vocabularies, one
    # page apart in the same workflow, which the walk lost time to. So the
    # refusal teaches rather than just declining.
    my $m = Lazysite::Handlers::action_form_uploads_save( 'contact', 1, { accept => 'image/*' } );
    ok( !$m->{ok}, 'a media type is refused' );
    like( $m->{error}, qr/EXTENSIONS/, 'and the refusal says which vocabulary this is' );
    like( $m->{error}, qr/png, jpg, pdf/, 'with an example' );
    like( $m->{error}, qr/page grammar/,
        'and names the other one, so the reader can tell them apart' );
};

subtest 'SM913: a quarantined submission gets no acknowledgement' => sub {
    my $d = a_site();
    my $note = Lazysite::Handlers::_acknowledge_submitter(
        { mail_the_submitter_field => 'email' },
        { email => 'ada@example.net', _quarantined => 1 },
        {}, '/nonexistent/form-smtp.pl',
    );
    like( $note, qr/quarantine/, 'it declines, and says why' );
    like( $note, qr/address somebody else chose/,
        'naming the reason rather than just the state' )
        or diag( 'Held back from the bell but answered by email is not a '
            . 'consistent position: the second is the louder act.' );

    # The control: the same call without the flag gets as far as the transport,
    # which is absent here - so the note is about the mail, not the quarantine.
    my $sent = Lazysite::Handlers::_acknowledge_submitter(
        { mail_the_submitter_field => 'email' },
        { email => 'ada@example.net' },
        {}, '/nonexistent/form-smtp.pl',
    );
    unlike( $sent, qr/quarantine/, 'an ordinary submission is not refused for it' );
};

done_testing();
