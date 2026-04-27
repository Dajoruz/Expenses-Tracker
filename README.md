XPNS (Provisional Name)

XPNS is a lightweight, web-based expense tracker designed for individuals and couples. This project was developed as a hobby to simplify personal finance tracking and shared spending transparency.
🚀 Features

    Simple Logging: Quickly record expenses with a name, amount, and category.

    Partner Sync: Link accounts with a partner to view shared/divided spending in real-time.

    Data Visualization: Interactive dashboards to monitor spending habits and trends.

    Data Portability: Export and download your recorded data for external use.

    Non-Profit: Created purely as a personal tool and learning exercise.

🛠️ Tech Stack

    Backend: Python with Flask

    Database: SQLite (Lightweight, serverless mapping)

    Frontend: HTML5, CSS3 (Custom UI)

📦 Installation & Setup

To run this project locally, ensure you have Python installed.

    Clone the repository:
    Bash

    git clone https://github.com/your-username/xpns.git
    cd xpns

    Set up a virtual environment:
    Bash

    python -m venv venv
    source venv/bin/activate  # On Windows: venv\Scripts\activate

    Install dependencies:
    (Make sure to create a requirements.txt if you haven't yet)
    Bash

    pip install flask

    Initialize the Database:
    The app uses SQLite, so the database will be created automatically upon the first run or via a provided schema script.

    Run the application:
    Bash

    python app.py

    Access the app at http://127.0.0.1:5000.

📈 Roadmap / Future Updates

    [ ] Implement a more robust "CVS" (Shared Expense) logic.

    [ ] Add more granular category filtering.

    [ ] Finalize the branding and move away from the "XPNS" placeholder.

📄 License

This project is for personal use and is not-for-profit. Feel free to fork it for your own personal hobby use.