package ms.rohde.wifpoc.servicer;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.SupplierJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;

/**
 * Enforcement side of the authorization split: which scope protects which endpoint.
 * Which workload receives which scope is decided by the domain's authorization server, not here.
 */
@Configuration
public class SecurityConfig {

    static final String READ = "SCOPE_r:orders:read";
    static final String WRITE = "SCOPE_r:orders:write";
    static final String ADMIN = "SCOPE_r:orders:admin";

    private static final String CLIENT_ID_CLAIM = "azp";

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) {
        return http
                .authorizeHttpRequests(requests -> requests
                        .requestMatchers(HttpMethod.GET, "/healthz").permitAll()
                        .requestMatchers(HttpMethod.GET, "/orders").hasAuthority(READ)
                        .requestMatchers(HttpMethod.POST, "/orders").hasAuthority(WRITE)
                        .requestMatchers(HttpMethod.DELETE, "/orders/*").hasAuthority(ADMIN)
                        .anyRequest().denyAll())
                .oauth2ResourceServer(resourceServer -> resourceServer
                        .jwt(jwt -> jwt.jwtAuthenticationConverter(scopeAuthenticationConverter())))
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .csrf(csrf -> csrf.disable())
                .httpBasic(basic -> basic.disable())
                .formLogin(form -> form.disable())
                .anonymous(Customizer.withDefaults())
                .build();
    }

    /**
     * Discovers the realm's JWKS from its issuer URL on the first token, so R starts independently
     * of the authorization server; a failed discovery is retried with the next token. Accepts RS256
     * only and applies {@link AccessTokenValidators#forIssuerAndAudience}.
     */
    @Bean
    JwtDecoder jwtDecoder(ServiceRProperties properties) {
        return new SupplierJwtDecoder(() -> {
            NimbusJwtDecoder decoder = NimbusJwtDecoder.withIssuerLocation(properties.issuer())
                    .jwsAlgorithm(SignatureAlgorithm.RS256)
                    .build();
            decoder.setJwtValidator(
                    AccessTokenValidators.forIssuerAndAudience(properties.issuer(), properties.audience()));
            return decoder;
        });
    }

    /** Maps every entry of the {@code scope} claim to {@code SCOPE_<scope>}; the principal is the client ID. */
    static JwtAuthenticationConverter scopeAuthenticationConverter() {
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(new JwtGrantedAuthoritiesConverter());
        converter.setPrincipalClaimName(CLIENT_ID_CLAIM);
        return converter;
    }
}
