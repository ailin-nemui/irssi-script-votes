FROM debian:10-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		\
		build-essential \
		cpanminus \
		\
		liblwp-protocol-https-perl \
		\
	&& rm -rf /var/lib/apt/lists/*
# (2) CPAN dependencies
# (5) some Perl modules from auto.cpanfile

ENV PERL_MM_NONINTERACTIVE="1"

ADD cpanfile /cpan/cpanfile
RUN cpanm --quiet --installdeps --notest /cpan \
	&& rm -fr /root/.cpanm

ADD list-votes.pl /list-votes.pl

RUN perl -MExtUtils::MY -E'MY->fixin(@ARGV)' -- *.pl \
	&& chmod +x *.pl

ENTRYPOINT ["/list-votes.pl"]
