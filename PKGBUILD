pkgname=owntracks-prometheus-relay
pkgver=2024.11.16
pkgrel=6
pkgdesc="Relay data from owntracks application to prometheus"
arch=('any')
url="https://github.com/sparky/$pkgname"
license=('GPL2')
depends=('uwsgi-plugin-psgi')
optdepends=(
	'nginx: HTTP server'
	'prometheus: Scrape data locally (remote setup is also an option)'
)
source=("${pkgname}-head::git+file://$PWD")
sha256sums=('SKIP')

package() {
	cd "${pkgname}-head"
	install -d \
		$pkgdir/usr/share/uwsgi \
		$pkgdir/etc/uwsgi/owntracks/prometheus
	install -m0644 -t $pkgdir/usr/share/uwsgi owntracks-prometheus-relay.psgi

	# XXX: the uwsgi@.service uses %I for the ini file. This means any dashes
	# will be replaced by / before evaluating.
	install -m0644 owntracks-prometheus-relay.ini $pkgdir/etc/uwsgi/owntracks/prometheus/relay.ini
}
