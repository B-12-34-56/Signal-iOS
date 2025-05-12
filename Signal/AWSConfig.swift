import AWSCore

public class AWSConfig {
    private static let poolId = "REPLACE_WITH_YOUR_POOL_ID"
    private static let region = AWSRegionType.USEast1
    
    public static func configure() {
        let credentialsProvider = AWSCognitoCredentialsProvider(
            regionType: region,
            identityPoolId: poolId
        )
        
        let configuration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialsProvider
        )
        
        AWSServiceManager.default().defaultServiceConfiguration = configuration
    }
    
    public static func getDynamoDBTableName() -> String {
        return "REPLACE_WITH_TABLE"
    }
} 