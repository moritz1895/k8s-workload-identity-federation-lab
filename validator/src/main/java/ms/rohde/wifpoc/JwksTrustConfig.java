package ms.rohde.wifpoc;

import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.JWKSourceBuilder;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jose.util.DefaultResourceRetriever;
import java.io.InputStream;
import java.net.URI;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.Collection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManagerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the JWKS source. The validator trusts exactly one CA — the one that signed the cluster API
 * server's serving certificate — and loads the JWKS over the network from the issuer URL, so the
 * {@code iss} claim must resolve from inside this container.
 */
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(WifProperties.class)
class JwksTrustConfig {

    private static final int CONNECT_TIMEOUT_MS = 2_000;
    private static final int READ_TIMEOUT_MS = 2_000;
    private static final int SIZE_LIMIT_BYTES = 64 * 1024;
    private static final long JWKS_CACHE_TTL_MS = 300_000L;
    private static final long JWKS_CACHE_REFRESH_TIMEOUT_MS = 30_000L;

    @Bean
    JWKSource<SecurityContext> jwkSource(WifProperties props) throws Exception {
        DefaultResourceRetriever retriever = new DefaultResourceRetriever(
                CONNECT_TIMEOUT_MS, READ_TIMEOUT_MS, SIZE_LIMIT_BYTES, true, trustOnly(props.clusterCa()));

        URL jwksUrl = URI.create(props.issuer() + "/openid/v1/jwks").toURL();
        return JWKSourceBuilder.<SecurityContext>create(jwksUrl, retriever)
                .cache(JWKS_CACHE_TTL_MS, JWKS_CACHE_REFRESH_TIMEOUT_MS)
                .rateLimited(false)
                .build();
    }

    @Bean
    TokenValidator tokenValidator(JWKSource<SecurityContext> jwkSource, WifProperties props) {
        return new TokenValidator(jwkSource, props.issuer(), props.audience());
    }

    private static SSLSocketFactory trustOnly(Path caPem) throws Exception {
        CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
        Collection<? extends Certificate> caCertificates;
        try (InputStream in = Files.newInputStream(caPem)) {
            caCertificates = certificateFactory.generateCertificates(in);
        }

        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null);
        int index = 0;
        for (Certificate caCertificate : caCertificates) {
            trustStore.setCertificateEntry("cluster-ca-" + index++, caCertificate);
        }

        TrustManagerFactory trustManagerFactory =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trustManagerFactory.init(trustStore);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(null, trustManagerFactory.getTrustManagers(), null);
        return sslContext.getSocketFactory();
    }
}
