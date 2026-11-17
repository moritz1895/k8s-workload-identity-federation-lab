package ms.rohde.wifpoc.servicer;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class ServiceRApplication {

    public static void main(String[] args) {
        SpringApplication.run(ServiceRApplication.class, args);
    }
}
