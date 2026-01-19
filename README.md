# Political Representation Dashboard

A web dashboard visualizing the alignment between Swiss political institutions (Parliament, Bundesrat, political parties) and the Swiss public, based on data from the [Swissvotes](https://swissvotes.ch) dataset.

Developed as part of a student project at **Berner Fachhochschule (BFH)**.

---

##  Features

-  Visualizations showing agreement between institutions and public votes
-  Party and canton-based filtering
-  Choropleth map of cantonal representation
-  Multilingual UI (DE, FR, IT, EN)
-  Automated daily data fetching from Swissvotes

---

##  Technologies

**Frontend** (Vue 3 + Vite + D3)
- Vue 3, Vue Router, Vue I18n
- D3.js for data visualization
- Tailwind CSS for styling
- TypeScript

**Backend**
- Node.js, Express
- PostgreSQL (with Docker)
- Axios, csv-parser, node-cron
- TypeScript + Vitest

---

## Deployment

This deployment works on macOS, Linux, and Windows.

### Remote deployment (Scope of Version 2.0)
Prerequisites: SSH port, remote host (IP or domain), and sudo or root access on the target machine.

#### 1. Download the repo using `git clone` or ZIP download on the Github webpage 
```bash
git clone https://github.com/lucanoahcaprez/BFH-Political-Representation-Dashboard.git
```
#### 2a. Change directory (if cloned by GIT like in step 1)
```bash
cd BFH-Political-Representation-Dashboard/deploy
```
#### 2b. Change directory (if downloaded using GitHub ZIP download)
```bash
cd BFH-Political-Representation-Dashboard-main/deploy
```
#### 3. Make it executable (macOS, Linux, WSL, Git Bash) -> Windows user don't have to do this part
```bash
chmod +x ../deploy
```
#### 4. Run the script (macOS, Linux, WSL, Git Bash)
```bash
./deploy-remote.sh
```

Windows users: run `deploy-remote.ps1` in PowerShell.

For more information about the deployment, how it works under the hood and how to adjust your Pesk setup for productive operations, please see `deploy/README.md` for details.

### Local deployment (Scope of Version 1.0)
> On macOS, the script uses [Colima](https://github.com/abiosoft/colima) instead of Docker Desktop.
> Colima is automatically installed if Docker is not already running, making the setup lightweight and M1/M2-compatible. Colima is a container runtime for macOS that replaces Docker Desktop and integrates well with the Docker CLI.

#### 1. Download the deployment script
```bash
curl -O https://raw.githubusercontent.com/lucanoahcaprez/BFH-Political-Representation-Dashboard/main/deploy-server.sh
```
#### 2. Make it executable (macOS, Linux, WSL, Git Bash)
```bash
chmod +x deploy-server.sh
```
#### 3. Run the deployment script
```bash
./deploy-server.sh
```
Windows users: Please use Git Bash or WSL (Windows Subsystem for Linux) to run the script.
Do not run it in Command Prompt or PowerShell.

Frontend: http://localhost:8080  
Backend API: http://localhost:3000/api

---
## Data Synchronization

The backend automatically fetches updated vote data every 4 hours using a cron job.

To manually trigger a data update:

```bash
docker-compose exec backend npm run update-data
```

---

## Backup

### Database Backup

Create a snapshot of the PostgreSQL data:

```bash
docker-compose exec db pg_dump -U postgres political_dashboard > backup.sql
```

---

## Data Source

This project uses data from the [Swissvotes dataset](https://swissvotes.ch/page/dataset), which is licensed under the **Creative Commons Attribution 4.0 International (CC BY 4.0)** license.  
**Source:** Swissvotes (2024), Année Politique Suisse, University of Bern.
This dataset is regularly accessed via automated fetches. For the most recent access date, refer to the backend logs.

---

##  FAQ

### What is the BFH Political Representation Dashboard?
It is a web dashboard that visualizes the alignment between Swiss political institutions (Parliament, Bundesrat, political parties) and the Swiss public using the Swissvotes dataset; developed as a student project at the Bern University of Applied Sciences (BFH) under the MIT license.

### What data source does the dashboard use?
The application uses the Swissvotes dataset, which is regularly accessed and visualized to show agreement levels between public votes and institutions. If the dashboard throws an error with fetching data, you can get in touch with the responsible teams at [https://swissvotes.ch/page/home](https://swissvotes.ch/page/home).

### If I am redeploying the app, what kind of persistence is provided?
There is no  persistence implemented. The app provides additional external persistence mechanisms using Swissvote. Data is stored in PostgreSQL and must be preserved across redeployments manually (for example, via database backups). The deployment script removes all volumes using `docker compose down -v`.

### Does the app automatically fetch or update data?
The backend automatically fetches updated vote data at regular intervals (every 4 hours) using a cron job.

### Is there a built-in backup mechanism?
No automated backup mechanism is included; manual backups (e.g., using pg_dump or docker volume copy mechanisms) are necessary to retain data.

### Can I use this project in my own environment?
Yes - you can clone the repository, build the frontend and backend locally, and deploy with Docker Compose in macOS, Linux, or Windows (via Git Bash/WSL).

---

##  Project Team

### Version 1.0
- **Damian Lienhart**
- **Sujal Singh Basnet**

### Version 2.0
- **Elia Bucher**
- **Luca Caprez**
- **Pascal Feller**

Project supervised by **Dr. Simon Kramer** (BFH)

---

## License

This project is licensed under the **MIT License** – see [`LICENSE`](./LICENSE) for details.

All dependencies are open source and MIT-compatible – see `package.json` for exact versions.

> Note: While this codebase is MIT-licensed, it integrates open government data under CC BY 4.0. If you reuse this project and include the data, please ensure you also comply with the attribution terms of the Swissvotes dataset.
