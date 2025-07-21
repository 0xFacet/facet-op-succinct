import * as fs from 'fs';
import * as path from 'path';

/**
 * Load environment variables from a file that may contain export statements
 * @param envPath Path to the .env file
 */
export function loadEnvFile(envPath: string) {
  try {
    const envContent = fs.readFileSync(envPath, 'utf-8');
    const lines = envContent.split('\n');
    
    for (const line of lines) {
      const trimmed = line.trim();
      
      // Skip empty lines and comments
      if (!trimmed || trimmed.startsWith('#')) continue;
      
      // Handle export statements
      let envLine = trimmed;
      if (trimmed.startsWith('export ')) {
        envLine = trimmed.substring(7).trim();
      }
      
      // Parse KEY=VALUE
      const equalIndex = envLine.indexOf('=');
      if (equalIndex > 0) {
        const key = envLine.substring(0, equalIndex).trim();
        let value = envLine.substring(equalIndex + 1).trim();
        
        // Remove quotes if present
        if ((value.startsWith('"') && value.endsWith('"')) || 
            (value.startsWith("'") && value.endsWith("'"))) {
          value = value.slice(1, -1);
        }
        
        // Only set if not already defined
        if (!process.env[key]) {
          process.env[key] = value;
        }
      }
    }
  } catch (error) {
    console.error(`Failed to load env file ${envPath}:`, error);
  }
}

// Try to load .env.sepolia from parent directory if it exists
export function loadSepoliaEnv() {
  const possiblePaths = [
    path.join(process.cwd(), '.env.sepolia'),
    path.join(process.cwd(), '..', '.env.sepolia'),
    path.join(process.cwd(), '..', 'contracts', '.env.sepolia'),
  ];
  
  for (const envPath of possiblePaths) {
    if (fs.existsSync(envPath)) {
      console.log(`Loading environment from ${envPath}`);
      loadEnvFile(envPath);
      return;
    }
  }
  
  console.log('No .env.sepolia file found, using defaults');
}