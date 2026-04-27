"""
XPNS v3 — Enhanced Expense Tracker with Couple Mode
Flask + SQLite | Port 5002
"""

from flask import Flask, request, jsonify, render_template, session, Response
from flask_cors import CORS
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime, date, timedelta
from calendar import monthrange
from functools import wraps
import uuid, os, csv, io

# ── Setup ─────────────────────────────────────────────────────────────────────

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(BASE_DIR, 'templates'), exist_ok=True)

app = Flask(__name__, template_folder=os.path.join(BASE_DIR, 'templates'))
CORS(app, supports_credentials=True)

app.config.update(
    SQLALCHEMY_DATABASE_URI       = f'sqlite:///{BASE_DIR}/xpns_v3.db',
    SQLALCHEMY_TRACK_MODIFICATIONS= False,
    SECRET_KEY                    = 'xpns-v3-2026-dajorus',
    SESSION_COOKIE_HTTPONLY       = True,
    SESSION_COOKIE_SAMESITE       = 'Lax',
    PERMANENT_SESSION_LIFETIME    = timedelta(days=30),
)

db = SQLAlchemy(app)

# ── Models ────────────────────────────────────────────────────────────────────

class User(db.Model):
    __tablename__   = 'users'
    id              = db.Column(db.String(36), primary_key=True,
                                default=lambda: str(uuid.uuid4()))
    username        = db.Column(db.String(50),  unique=True, nullable=False)
    password_hash   = db.Column(db.String(255), nullable=False)
    display_name    = db.Column(db.String(100))
    currency        = db.Column(db.String(3),   default='MXN')
    daily_budget    = db.Column(db.Float)
    couple_username = db.Column(db.String(50))
    couple_split    = db.Column(db.Float, default=50.0)
    created_at      = db.Column(db.DateTime, default=datetime.utcnow)
    last_login      = db.Column(db.DateTime)
    created_by_ip   = db.Column(db.String(45))
    expenses        = db.relationship('Expense', backref='user', lazy=True,
                                      foreign_keys='Expense.user_id')

    def to_dict(self):
        return {
            'id':              self.id,
            'username':        self.username,
            'display_name':    self.display_name or self.username,
            'currency':        self.currency,
            'daily_budget':    self.daily_budget,
            'couple_username': self.couple_username,
            'couple_split':    self.couple_split,
            'created_at':      self.created_at.isoformat(),
        }


class Expense(db.Model):
    __tablename__      = 'expenses'
    id                 = db.Column(db.String(36), primary_key=True,
                                   default=lambda: str(uuid.uuid4()))
    user_id            = db.Column(db.String(36), db.ForeignKey('users.id'), nullable=False)
    article            = db.Column(db.String(100), nullable=False)
    category           = db.Column(db.String(50),  nullable=False)
    amount             = db.Column(db.Float, nullable=False)
    description        = db.Column(db.String(250))
    expense_date       = db.Column(db.Date,    default=date.today)
    is_divided         = db.Column(db.Boolean, default=False)
    divided_count      = db.Column(db.Integer, default=1)
    # Couple / shared fields
    amount_paid        = db.Column(db.Float)          # full amount the payer actually paid
    amount_owed_to_you = db.Column(db.Float, default=0.0)  # partner's debt to you
    is_couple_expense  = db.Column(db.Boolean, default=False)
    partner_expense_id = db.Column(db.String(36))     # link to partner's mirrored record
    created_at         = db.Column(db.DateTime, default=datetime.utcnow)
    created_by_ip      = db.Column(db.String(45))
    is_deleted         = db.Column(db.Boolean, default=False)

    @property
    def eff(self):
        """Effective cost to this user."""
        if self.is_divided and self.divided_count > 1:
            return round(self.amount / self.divided_count, 2)
        return round(self.amount, 2)

    def to_dict(self):
        return {
            'id':                 self.id,
            'article':            self.article,
            'category':           self.category,
            'amount':             round(self.amount, 2),
            'eff_amount':         self.eff,
            'description':        self.description or '',
            'expense_date':       self.expense_date.isoformat(),
            'is_divided':         self.is_divided,
            'divided_count':      self.divided_count,
            'amount_paid':        self.amount_paid,
            'amount_owed_to_you': self.amount_owed_to_you or 0,
            'is_couple_expense':  bool(self.is_couple_expense),
            'partner_expense_id': self.partner_expense_id,
            'created_at':         self.created_at.isoformat(),
        }


# ── DB init + migration ───────────────────────────────────────────────────────

with app.app_context():
    db.create_all()
    _new_cols = [
        "ALTER TABLE expenses ADD COLUMN amount_paid REAL",
        "ALTER TABLE expenses ADD COLUMN amount_owed_to_you REAL DEFAULT 0",
        "ALTER TABLE expenses ADD COLUMN is_couple_expense BOOLEAN DEFAULT 0",
        "ALTER TABLE expenses ADD COLUMN partner_expense_id VARCHAR(36)",
    ]
    with db.engine.connect() as _conn:
        for _sql in _new_cols:
            try:
                _conn.execute(text(_sql))
                _conn.commit()
            except Exception:
                pass  # column already exists

# ── Constants ─────────────────────────────────────────────────────────────────

CATEGORIES = [
    {'name': 'Food',          'color': '#00ff88', 'emoji': '🍔'},
    {'name': 'Transport',     'color': '#00d4ff', 'emoji': '🚗'},
    {'name': 'Entertainment', 'color': '#b44fff', 'emoji': '🎬'},
    {'name': 'Utilities',     'color': '#ff6b00', 'emoji': '💡'},
    {'name': 'Shopping',      'color': '#ff3da6', 'emoji': '🛍️'},
    {'name': 'Health',        'color': '#ffe600', 'emoji': '🏥'},
    {'name': 'Education',     'color': '#00ffcc', 'emoji': '📚'},
    {'name': 'Other',         'color': '#888899', 'emoji': '📌'},
]
CAT_MAP = {c['name']: c for c in CATEGORIES}

# ── Helpers ───────────────────────────────────────────────────────────────────

def get_ip():
    return request.headers.get('X-Forwarded-For', request.remote_addr)

def require_auth(f):
    @wraps(f)
    def deco(*args, **kwargs):
        uid = session.get('user_id')
        if not uid:
            return jsonify({'error': 'Unauthorized'}), 401
        user = User.query.get(uid)
        if not user:
            session.clear()
            return jsonify({'error': 'Unauthorized'}), 401
        return f(user, *args, **kwargs)
    return deco

def _get_range_expenses(uid, from_d, to_d):
    return Expense.query.filter(
        Expense.user_id      == uid,
        Expense.expense_date >= from_d,
        Expense.expense_date <= to_d,
        Expense.is_deleted   == False,
    ).all()

# ── Auth ──────────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    return render_template('app_v3.html')

@app.route('/api/auth/register', methods=['POST'])
def register():
    d            = request.get_json()
    username     = (d.get('username') or '').strip().lower()
    password     = d.get('password') or ''
    display_name = (d.get('display_name') or '').strip()

    if len(username) < 3:
        return jsonify({'error': 'Username must be at least 3 characters'}), 400
    if len(password) < 7:
        return jsonify({'error': 'Password must be at least 7 characters'}), 400
    if User.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already taken'}), 409

    user = User(
        username     = username,
        password_hash= generate_password_hash(password),
        display_name = display_name or username,
        created_by_ip= get_ip(),
        last_login   = datetime.utcnow(),
    )
    db.session.add(user)
    db.session.commit()

    session.permanent  = True
    session['user_id'] = user.id
    return jsonify({'status': 'success', 'user': user.to_dict()}), 201

@app.route('/api/auth/login', methods=['POST'])
def login():
    d        = request.get_json()
    username = (d.get('username') or '').strip().lower()
    password = d.get('password') or ''
    remember = d.get('remember', False)

    user = User.query.filter_by(username=username).first()
    if not user or not check_password_hash(user.password_hash, password):
        return jsonify({'error': 'Invalid username or password'}), 401

    user.last_login = datetime.utcnow()
    db.session.commit()

    session.permanent  = bool(remember)
    session['user_id'] = user.id
    return jsonify({'status': 'success', 'user': user.to_dict()})

@app.route('/api/auth/logout', methods=['POST'])
def logout():
    session.clear()
    return jsonify({'status': 'success'})

@app.route('/api/auth/me')
def me():
    uid = session.get('user_id')
    if not uid:
        return jsonify({'logged_in': False})
    user = User.query.get(uid)
    if not user:
        session.clear()
        return jsonify({'logged_in': False})
    return jsonify({'logged_in': True, 'user': user.to_dict()})

# ── Expenses ──────────────────────────────────────────────────────────────────

@app.route('/api/expenses', methods=['GET'])
@require_auth
def get_expenses(user):
    limit      = min(int(request.args.get('limit', 20)), 200)
    search     = request.args.get('q', '').strip()
    category   = request.args.get('category', '').strip()
    from_d     = request.args.get('from')
    to_d       = request.args.get('to')
    today_only = request.args.get('today') == 'true'

    q = Expense.query.filter_by(user_id=user.id, is_deleted=False)
    if today_only:
        q = q.filter(Expense.expense_date == date.today())
    if search:
        q = q.filter(Expense.article.ilike(f'%{search}%'))
    if category:
        q = q.filter_by(category=category)
    if from_d:
        try: q = q.filter(Expense.expense_date >= date.fromisoformat(from_d))
        except: pass
    if to_d:
        try: q = q.filter(Expense.expense_date <= date.fromisoformat(to_d))
        except: pass

    expenses = q.order_by(Expense.created_at.desc()).limit(limit).all()
    return jsonify({'expenses': [e.to_dict() for e in expenses]})


@app.route('/api/expenses', methods=['POST'])
@require_auth
def create_expense(user):
    d           = request.get_json()
    article     = (d.get('article') or '').strip()
    category    = (d.get('category') or '').strip()
    amount      = d.get('amount')
    description = (d.get('description') or '').strip()
    exp_date    = d.get('expense_date')
    is_divided  = bool(d.get('is_divided', False))

    if not article:  return jsonify({'error': 'Article required'}), 400
    if not category: return jsonify({'error': 'Category required'}), 400
    try:
        amt = round(float(amount), 2)
        if amt <= 0: raise ValueError
    except:
        return jsonify({'error': 'Invalid amount'}), 400

    try:
        parsed_date = date.fromisoformat(exp_date) if exp_date else date.today()
    except:
        parsed_date = date.today()

    # Couple mode: only active when is_divided + partner is configured
    is_couple = is_divided and bool(user.couple_username)

    e = Expense(
        user_id            = user.id,
        article            = article[:100],
        category           = category[:50],
        amount             = amt,
        description        = description[:250] if description else None,
        expense_date       = parsed_date,
        is_divided         = is_divided,
        divided_count      = 2 if is_divided else 1,
        amount_paid        = amt if is_couple else None,
        amount_owed_to_you = round(amt / 2, 2) if is_couple else 0.0,
        is_couple_expense  = is_couple,
        created_by_ip      = get_ip(),
    )
    db.session.add(e)
    db.session.flush()  # get e.id before commit

    partner_created = False
    if is_couple:
        partner = User.query.filter_by(username=user.couple_username).first()
        if partner:
            payer_name = user.display_name or user.username
            p_desc = f"Split with {payer_name}"
            if description:
                p_desc += f" · {description[:200]}"
            partner_exp = Expense(
                user_id            = partner.id,
                article            = article[:100],
                category           = category[:50],
                amount             = round(amt / 2, 2),   # partner's share
                description        = p_desc[:250],
                expense_date       = parsed_date,
                is_divided         = False,
                divided_count      = 1,
                amount_paid        = 0.0,
                amount_owed_to_you = 0.0,
                is_couple_expense  = True,
                partner_expense_id = e.id,
                created_by_ip      = get_ip(),
            )
            db.session.add(partner_exp)
            partner_created = True

    db.session.commit()
    return jsonify({
        'status':               'success',
        'expense':              e.to_dict(),
        'couple_expense_created': partner_created,
    }), 201


@app.route('/api/expenses/<eid>', methods=['DELETE'])
@require_auth
def delete_expense(user, eid):
    e = Expense.query.filter_by(id=eid, user_id=user.id, is_deleted=False).first()
    if not e: return jsonify({'error': 'Not found'}), 404
    e.is_deleted = True
    db.session.commit()
    return jsonify({'status': 'success'})


@app.route('/api/expenses/bulk-delete', methods=['POST'])
@require_auth
def bulk_delete(user):
    ids = request.get_json().get('ids', [])
    if not ids: return jsonify({'error': 'No IDs'}), 400
    Expense.query.filter(
        Expense.id.in_(ids), Expense.user_id == user.id
    ).update({'is_deleted': True}, synchronize_session=False)
    db.session.commit()
    return jsonify({'status': 'success', 'deleted': len(ids)})

# ── CSV Export ────────────────────────────────────────────────────────────────

@app.route('/api/export/csv')
@require_auth
def export_csv(user):
    expenses = Expense.query.filter_by(
        user_id=user.id, is_deleted=False
    ).order_by(Expense.expense_date.desc(), Expense.created_at.desc()).all()

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow([
        'date', 'article', 'category', 'amount', 'effective_amount',
        'description', 'is_divided', 'is_couple_expense',
        'amount_paid', 'amount_owed_to_you', 'created_at',
    ])
    for ex in expenses:
        writer.writerow([
            ex.expense_date.isoformat(),
            ex.article,
            ex.category,
            ex.amount,
            ex.eff,
            ex.description or '',
            ex.is_divided,
            ex.is_couple_expense or False,
            ex.amount_paid if ex.amount_paid is not None else '',
            ex.amount_owed_to_you or 0,
            ex.created_at.isoformat(),
        ])

    buf.seek(0)
    filename = f'xpns_{user.username}_{date.today().isoformat()}.csv'
    return Response(
        buf.getvalue(),
        mimetype='text/csv; charset=utf-8',
        headers={'Content-Disposition': f'attachment; filename="{filename}"'},
    )

# ── Stats ─────────────────────────────────────────────────────────────────────

@app.route('/api/stats/today')
@require_auth
def stats_today(user):
    today    = date.today()
    expenses = Expense.query.filter_by(
        user_id=user.id, expense_date=today, is_deleted=False
    ).all()
    total  = sum(e.eff for e in expenses)
    by_cat = {}
    for e in expenses:
        by_cat[e.category] = round(by_cat.get(e.category, 0) + e.eff, 2)
    return jsonify({
        'date':        today.isoformat(),
        'total':       round(total, 2),
        'by_category': by_cat,
        'count':       len(expenses),
    })


@app.route('/api/stats/week')
@require_auth
def stats_week(user):
    today = date.today()
    days  = []
    for i in range(6, -1, -1):
        d    = today - timedelta(days=i)
        exps = Expense.query.filter_by(user_id=user.id, expense_date=d, is_deleted=False).all()
        days.append({
            'date':     d.isoformat(),
            'label':    d.strftime('%a'),
            'total':    round(sum(e.eff for e in exps), 2),
            'is_today': d == today,
        })
    return jsonify({'days': days})


@app.route('/api/stats/dashboard')
@require_auth
def stats_dashboard(user):
    today      = date.today()
    year, month = today.year, today.month
    first_month = date(year, month, 1)
    last_month  = date(year, month, monthrange(year, month)[1])
    first_year  = date(year, 1,     1)
    last_year   = date(year, 12,    31)

    month_exps = _get_range_expenses(user.id, first_month, last_month)
    year_exps  = _get_range_expenses(user.id, first_year,  last_year)

    # Category breakdown — current month
    by_category = {}
    for e in month_exps:
        by_category[e.category] = round(by_category.get(e.category, 0) + e.eff, 2)

    # Monthly totals — current year
    monthly = []
    for m in range(1, 13):
        fd   = date(year, m, 1)
        ld   = date(year, m, monthrange(year, m)[1])
        exps = _get_range_expenses(user.id, fd, ld)
        monthly.append({
            'month':      fd.strftime('%b'),
            'num':        m,
            'total':      round(sum(e.eff for e in exps), 2),
            'is_current': m == month,
        })

    # Week (last 7 days) — for the small bar
    week_days = []
    for i in range(6, -1, -1):
        d    = today - timedelta(days=i)
        exps = Expense.query.filter_by(user_id=user.id, expense_date=d, is_deleted=False).all()
        week_days.append({
            'label':    'Today' if d == today else d.strftime('%a'),
            'total':    round(sum(e.eff for e in exps), 2),
            'is_today': d == today,
        })

    # Couple section
    couple = None
    if user.couple_username:
        partner = User.query.filter_by(username=user.couple_username).first()
        if partner:
            p_month_exps = _get_range_expenses(partner.id, first_month, last_month)
            my_total = round(sum(e.eff for e in month_exps), 2)
            p_total  = round(sum(e.eff for e in p_month_exps), 2)

            couple_monthly = []
            for m in range(1, 13):
                fd      = date(year, m, 1)
                ld      = date(year, m, monthrange(year, m)[1])
                my_exps = _get_range_expenses(user.id,    fd, ld)
                p_exps  = _get_range_expenses(partner.id, fd, ld)
                couple_monthly.append({
                    'month':         fd.strftime('%b'),
                    'my_total':      round(sum(e.eff for e in my_exps), 2),
                    'partner_total': round(sum(e.eff for e in p_exps),  2),
                })

            couple = {
                'my_name':      user.display_name    or user.username,
                'partner_name': partner.display_name or partner.username,
                'my_total':     my_total,
                'partner_total': p_total,
                'combined':     round(my_total + p_total, 2),
                'monthly':      couple_monthly,
            }

    # Total owed to user (current month, couple expenses)
    owed = round(sum(e.amount_owed_to_you or 0 for e in month_exps if e.is_couple_expense), 2)

    return jsonify({
        'by_category':   by_category,
        'monthly':       monthly,
        'week':          week_days,
        'couple':        couple,
        'month_total':   round(sum(e.eff for e in month_exps), 2),
        'year_total':    round(sum(e.eff for e in year_exps),  2),
        'owed_to_me':    owed,
        'current_month': today.strftime('%B %Y'),
        'current_year':  year,
    })


@app.route('/api/stats/history')
@require_auth
def stats_history(user):
    view    = request.args.get('view', '7days')
    ref_str = request.args.get('date', date.today().isoformat())
    try:
        ref = date.fromisoformat(ref_str)
    except:
        ref = date.today()

    groups = []

    if view == '7days':
        for i in range(6, -1, -1):
            d    = date.today() - timedelta(days=i)
            exps = Expense.query.filter_by(user_id=user.id, expense_date=d, is_deleted=False)\
                                .order_by(Expense.created_at.desc()).all()
            groups.append({
                'label':    d.strftime('%A, %d %b'),
                'date':     d.isoformat(),
                'total':    round(sum(e.eff for e in exps), 2),
                'expenses': [e.to_dict() for e in exps],
                'is_today': d == date.today(),
            })

    elif view == 'month':
        year2, month2 = ref.year, ref.month
        first         = date(year2, month2, 1)
        last          = date(year2, month2, monthrange(year2, month2)[1])
        week_start, week_num = first, 1
        while week_start <= last:
            week_end = min(week_start + timedelta(days=6), last)
            exps     = Expense.query.filter(
                Expense.user_id      == user.id,
                Expense.expense_date >= week_start,
                Expense.expense_date <= week_end,
                Expense.is_deleted   == False,
            ).order_by(Expense.expense_date.desc(), Expense.created_at.desc()).all()
            groups.append({
                'label':      f'Week {week_num}  ·  {week_start.strftime("%d")}–{week_end.strftime("%d %b")}',
                'date_start': week_start.isoformat(),
                'date_end':   week_end.isoformat(),
                'total':      round(sum(e.eff for e in exps), 2),
                'expenses':   [e.to_dict() for e in exps],
            })
            week_start  = week_end + timedelta(days=1)
            week_num   += 1

    elif view == 'year':
        for m in range(1, 13):
            first = date(ref.year, m, 1)
            last  = date(ref.year, m, monthrange(ref.year, m)[1])
            exps  = Expense.query.filter(
                Expense.user_id      == user.id,
                Expense.expense_date >= first,
                Expense.expense_date <= last,
                Expense.is_deleted   == False,
            ).order_by(Expense.expense_date.desc()).all()
            groups.append({
                'label':    first.strftime('%B %Y'),
                'month':    m,
                'year':     ref.year,
                'total':    round(sum(e.eff for e in exps), 2),
                'expenses': [e.to_dict() for e in exps],
            })

    return jsonify({'view': view, 'groups': groups})

# ── Autocomplete ──────────────────────────────────────────────────────────────

@app.route('/api/autocomplete')
@require_auth
def autocomplete(user):
    q = request.args.get('q', '').strip()
    if len(q) < 2: return jsonify({'articles': []})
    rows = db.session.query(Expense.article).filter(
        Expense.user_id    == user.id,
        Expense.article.ilike(f'%{q}%'),
        Expense.is_deleted == False,
    ).distinct().limit(5).all()
    return jsonify({'articles': [r[0] for r in rows]})

# ── Settings ──────────────────────────────────────────────────────────────────

@app.route('/api/settings')
@require_auth
def get_settings(user):
    return jsonify({'user': user.to_dict()})

@app.route('/api/settings', methods=['PUT'])
@require_auth
def update_settings(user):
    d = request.get_json()
    if 'display_name'    in d: user.display_name    = (d['display_name']    or '').strip()[:100]
    if 'currency'        in d: user.currency        = (d['currency']        or 'MXN').upper()[:3]
    if 'couple_username' in d: user.couple_username = (d['couple_username'] or '').strip()[:50] or None
    if 'daily_budget'    in d:
        try:   user.daily_budget = float(d['daily_budget']) if d['daily_budget'] else None
        except: pass
    if 'couple_split'    in d:
        try:   user.couple_split = max(0.0, min(100.0, float(d['couple_split'])))
        except: pass
    db.session.commit()
    return jsonify({'status': 'success', 'user': user.to_dict()})

@app.route('/api/settings/password', methods=['PUT'])
@require_auth
def change_password(user):
    d    = request.get_json()
    curr = d.get('current_password', '')
    new  = d.get('new_password', '')
    if not check_password_hash(user.password_hash, curr):
        return jsonify({'error': 'Current password is incorrect'}), 400
    if len(new) < 7:
        return jsonify({'error': 'New password must be at least 7 characters'}), 400
    user.password_hash = generate_password_hash(new)
    db.session.commit()
    return jsonify({'status': 'success'})

@app.route('/api/settings/account', methods=['DELETE'])
@require_auth
def delete_account(user):
    d = request.get_json()
    if not check_password_hash(user.password_hash, d.get('password', '')):
        return jsonify({'error': 'Incorrect password'}), 400
    Expense.query.filter_by(user_id=user.id).delete()
    db.session.delete(user)
    db.session.commit()
    session.clear()
    return jsonify({'status': 'success'})

# ── Misc ──────────────────────────────────────────────────────────────────────

@app.route('/api/categories')
def get_categories():
    return jsonify({'categories': CATEGORIES})

@app.route('/api/health')
def health():
    return jsonify({'status': 'healthy', 'service': 'xpns-v3'})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5002, debug=False, threaded=True)