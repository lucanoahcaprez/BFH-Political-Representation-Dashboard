import { Client } from 'pg'
import { fetchSwissvotesData } from './fetchSwissvotes'
import dotenv from 'dotenv'

dotenv.config()

export async function updateDatabase() {
    const client = new Client({
        connectionString: process.env.DATABASE_URL
    })

 try {
        await client.connect()
        console.log('[DB UPDATE] Connected to DB')
        console.log("Using DB URL:", process.env.DATABASE_URL)

        await fetchSwissvotesData(client)
        console.log("[DEBUG] Inserting timestamp update");
        await client.query(`
            INSERT INTO meta (key, value)
            VALUES ('last_update', (NOW() AT TIME ZONE 'Europe/Zurich')::TEXT)
                ON CONFLICT (key) DO UPDATE
                                         SET value = EXCLUDED.value;
        `);
        console.log("Timestamp updated to:", new Date().toISOString());

    } catch (err) {
        console.error('[DB UPDATE] Error:', err)
    } finally {
        await client.end()
        console.log('[DB UPDATE] Disconnected from DB')
    }
}
