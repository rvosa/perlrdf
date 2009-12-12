=head1 NAME

RDF::LinkedData - mod_perl handler class for serving RDF as linked data

=head1 METHODS

=over 4

=cut

package RDF::LinkedData;

use strict;
use warnings;

use Data::Dumper;
use Apache2::Request;
use Scalar::Util qw(blessed);
use HTTP::Negotiate qw(choose);
use URI::Escape qw(uri_escape);
use Apache2::Const qw(OK HTTP_SEE_OTHER REDIRECT DECLINED SERVER_ERROR HTTP_NO_CONTENT HTTP_NOT_IMPLEMENTED NOT_FOUND);

use RDF::Trine 0.113;
use RDF::Trine::Serializer::NTriples;
use RDF::Trine::Serializer::RDFXML;

use Error qw(:try);

=item C<< handler >> ( $apache_req )

Main mod_perl handler method.

=cut

sub handler : method {
	my $class 	= shift;
	my $r	  	= shift;
	
	my $status;
	
	my $handler	= $class->new( $r );
	if (!$handler) {
		warn "couldn't get a handler";
		return DECLINED;
	} else {
		return $handler->run();
	}
}

=item C<< new >> ( $apache_req )

Creates a new handler object, given an Apache Request object.

=cut

sub new {
	my $proto	= shift;
	my $class   = ref($proto) || $proto;
	my $r		= shift;
	throw Mentok::ArgumentError unless (ref $r);

	my $base		= $r->dir_config( 'LinkedData_Base' );
	my $dbmodel		= $r->dir_config( 'LinkedData_Model' );
	my $dbuser		= $r->dir_config( 'LinkedData_User' );
	my $dbpass		= $r->dir_config( 'LinkedData_Password' );
	my $dsn			= $r->dir_config( 'LinkedData_DSN' );
	my $store		= RDF::Trine::Store::DBI->new( $dbmodel, $dsn, $dbuser, $dbpass );
	my $model		= RDF::Trine::Model->new( $store );
	
	my $self = bless( {
		_r	=> $r,
		_model => $model,
		_base => $base,
	}, $class );

	return $self;
} # END sub new

sub request {
	my $self	= shift;
	return $self->{_r};
}

sub model {
	my $self	= shift;
	return $self->{_model};
}

sub base {
	my $self	= shift;
	return $self->{_base};
}

sub run {
	my $self	= shift;
	my $r		= $self->request;
	
	my $uri		= $r->uri;
	my $base	= $self->base;
	my $model	= $self->model;
	my $variants = [
		['html',	1.000, 'text/html', undef, undef, undef, 1],
		['html',	0.500, 'application/xhtml+xml', undef, undef, undef, 1],
		['rdf-nt',	0.900, 'text/plain', undef, undef, undef, 1],
		['rdf-nt',	0.900, 'text/rdf', undef, undef, undef, 1],
		['rdf-nt',  0.900, 'application/x-turtle', undef, undef, undef, 1],
		['rdf-nt',  0.900, 'application/turtle', undef, undef, undef, 1],
		['rdf-nt',  0.900, 'text/n3', undef, undef, undef, 1],
		['rdf-xml',	0.950, 'application/rdf+xml', undef, undef, undef, 1],
	];
	my $choice	= choose($variants) || 'html';
	
	if ($uri =~ m<^(.+)/(data|page)$>) {
		my $first	= $1;
		my $type	= $2;
		my $iri	= sprintf( '%s%s', $base, $first );
		
		# not happy with this, but it helps for clients that do content sniffing based on filename
		$iri	=~ s/.(nt|rdf|ttl)$//;
		
		my $node	= RDF::Trine::Node::Resource->new( $iri );
		my $count	= $model->count_statements( $node, undef, undef );
		
		$r->header_out('Vary', join ", ", qw(Accept));
		if ($count > 0) {
			if ($type eq 'data') {
				if ($choice =~ /nt/) {
					my $s		= RDF::Trine::Serializer::NTriples->new();
					my $string	= $s->_serialize_bounded_description( $model, $node );
					$r->content_type('text/plain');
					$r->print("# Data for <$iri>\n");
					$r->print($string);
					return OK;
				} else {
					my $s		= RDF::Trine::Serializer::RDFXML->new();
					my $string	= $s->_serialize_bounded_description( $model, $node );
					$r->content_type('application/rdf+xml');
					$r->print($string);
					return OK;
				}
			} else {
				my $title		= $self->_title( $node );
				my $desc		= $self->_description( $node );
				my $description	= sprintf( "<table>%s</table>\n", join("\n\t\t", map { sprintf( '<tr><td>%s</td><td>%s</td></tr>', @$_ ) } @$desc) );
				$r->content_type('text/html');
				$r->print(<<"END");
<?xml version="1.0"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML+RDFa 1.0//EN"
	 "http://www.w3.org/MarkUp/DTD/xhtml-rdfa-1.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
	<meta http-equiv="content-type" content="text/html; charset=utf-8" />
	<title>${title}</title>
</head>
<body xmlns:foaf="http://xmlns.com/foaf/0.1/">

<h1>${title}</h1>
<hr/>

<div>
	${description}
</div>

</body></html>
END
				return OK;
			}
		} else {
			return NOT_FOUND;
		}
	} else {
		$r->err_header_out('Vary', join ", ", qw(Accept));
		if ($choice =~ /^rdf/) {
			$r->err_header_out(Location => "${base}${uri}/data");
		} else {
			$r->err_header_out(Location => "${base}${uri}/page");
		}
		return HTTP_SEE_OTHER;
	}
}

sub _title {
	my $self	= shift;
	my $node	= shift;
	my $model	= $self->model;
	my $name	= RDF::Trine::Node::Resource->new( 'http://xmlns.com/foaf/0.1/name' );
	my $label	= RDF::Trine::Node::Resource->new( 'http://www.w3.org/2000/01/rdf-schema#label' );
	my $title	= RDF::Trine::Node::Resource->new( 'http://purl.org/dc/elements/1.1/title' );
	my @names	= $model->objects_for_predicate_list( $node, $name, $title, $label );
	foreach my $n (@names) {
		if ($n->is_literal) {
			return $n->literal_value;
		}
	}
	return $node->uri_value;
}

sub _description {
	my $self	= shift;
	my $node	= shift;
	my $model	= $self->model;
	my $iter	= $model->get_statements( $node );
	my $label	= RDF::Trine::Node::Resource->new( 'http://www.w3.org/2000/01/rdf-schema#label' );
	my @desc;
	while (my $st = $iter->next) {
		my $p	= $st->predicate;
		my @pn	= $model->objects_for_predicate_list( $p, $label );
		next unless (@pn);
		my $pn	= shift(@pn);
		my $ps	= $self->_html_node_value( $pn );
		
		my $obj	= $st->object;
		my $os	= $self->_html_node_value( $obj, $p );
		
		push(@desc, [$ps, $os]);
	}
	return \@desc;
}

sub _html_node_value {
	my $self		= shift;
	my $n			= shift;
	my $rdfapred	= shift;
	my $qname		= '';
	my $xmlns		= '';
	if ($rdfapred) {
		try {
			my ($ns, $ln)	= $rdfapred->qname;
			$xmlns	= qq[xmlns:ns="${ns}"];
			$qname	= qq[ns:$ln];
		};
	}
	return '' unless (blessed($n));
	if ($n->is_literal) {
		my $l	= _escape( $n->literal_value );
		if ($qname) {
			return qq[<span $xmlns property="${qname}">$l</span>];
		} else {
			return $l;
		}
	} elsif ($n->is_resource) {
		my $uri		= _escape( $n->uri_value );
		my $title	= _escape( $self->_title( $n ) );
		
		if ($qname) {
			return qq[<a $xmlns rel="${qname}" href="${uri}">$title</a>];
		} else {
			return qq[<a href="${uri}">$title</a>];
		}
	} else {
		return $n->as_string;
	}
}

sub _escape {
	my $l	= shift;
	for ($l) {
		s/&/&amp;/g;
		s/</&lt;/g;
		s/"/&quot;/g;
	}
	return $l;
}

1;

__END__

=back

=head1 AUTHOR

Gregory Todd Williams  C<< <gwilliams@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) 2009 Gregory Todd Williams. All rights reserved. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
