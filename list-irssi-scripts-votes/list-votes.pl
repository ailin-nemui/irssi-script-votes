#! perl
use strict;
use warnings;

use Net::GitHub::V3;
use CPAN::Meta::YAML 'DumpFile';
use JSON::PP;

sub ng {
    my $gh = Net::GitHub::V3->new(
	($ENV{GITHUB_TOKEN} ? (access_token => $ENV{GITHUB_TOKEN}) : ())
       );
    my $proj = "ailin-nemui/irssi-script-votes";
    my ($user, $project) = split '/', $proj, 2;
    return unless $user && $project;
    $gh->set_default_user_repo($user, $project);
    $gh
}

sub get_votes {
    my $ng = ng();
    # patch into Net/GitHub/V3/Issues.pm
    # my %__methods = (
    #    comments => { url => "/repos/%s/%s/issues/%s/comments", preview => "squirrel-girl-preview" },
    my $ua = $ng->ua;
    $ua->default_header(Accept => 'application/vnd.github.squirrel-girl-preview');
    my $iss = $ng->issue;
    my $start = 2;
    my @comm = $iss->comments($start);
    my %res;
 RST: while (1) {
	for my $c (@comm) {
	    $c->{body} =~ s/\r\n/\n/g;
	    if ($c->{body} =~ /\A## (.*?[._].*?)$/m || $c->{body} =~ /\A(.*?[._].*?)\n---\n/m) {
		my $script = $1;
		my $v_info = '';
		my $h;
		if ($c->{reactions}{total_count}) {
		    my $votes = 1+ $c->{reactions}{'+1'} - $c->{reactions}{'-1'};
		    my $hearts = $c->{reactions}{heart};
		    $h = $hearts >= $votes;
		    $v_info = $h ? $hearts
			: ($c->{reactions}{'+1'} || $c->{reactions}{'-1'}) ? $votes - 1 : '';
		}
		$res{$script} = +{ v => $v_info, u => $c->{html_url}, ($h ? (h => $h) : ()) };
	    } elsif ($c->{body} =~ /\A#(\d+)\Z/) {
		@comm = $iss->comments($1);
		next RST;
	    }
	}
	last;
    }
    \%res
}

sub main {
    my $res = get_votes();
    DumpFile('votes.yml', $res);
    my $json = JSON::PP->new->utf8->canonical(1)->pretty->encode($res);
    $json =~ s/\n\z//;
    open my $js, '>:raw', 'votes.js';
    print $js "addVotes($json)";
    close $js;
}

&main;
