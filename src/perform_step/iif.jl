mutable struct RHS_IIF1M_Scalar{F,CType,tType,P} <: Function
  f::F
  t::tType
  dt::tType
  tmp::CType
  p::P
end

function (f::RHS_IIF1M_Scalar)(resid,u)
  resid[1] .= u[1] - f.tmp - f.dt*f.f[2](u[1],f.p,f.t+f.dt)[1]
end

mutable struct RHS_IIF2M_Scalar{F,CType,tType,P} <: Function
  f::F
  t::tType
  dt::tType
  tmp::CType
  p::P
end

function (f::RHS_IIF2M_Scalar)(resid,u)
  resid[1] = u[1] - f.tmp - 0.5f.dt*f.f[2](u[1],f.p,f.t+f.dt)[1]
end

@muladd function initialize!(integrator,cache::Union{IIF1MConstantCache,IIF2MConstantCache,IIF1MilConstantCache},f=integrator.f)
  cache.uhold[1] = integrator.uprev
end

@muladd function perform_step!(integrator,cache::Union{IIF1MConstantCache,IIF2MConstantCache,IIF1MilConstantCache},f=integrator.f)
  @unpack t,dt,uprev,u,W,p = integrator
  @unpack uhold,rhs,nl_rhs = cache
  alg = typeof(integrator.alg) <: StochasticDiffEqCompositeAlgorithm ? integrator.alg.algs[integrator.alg.current_alg] : integrator.alg
  A = integrator.f[1](u,p,t)
  if typeof(cache) <: IIF1MilConstantCache
    error("Milstein correction does not work.")
  elseif typeof(cache) <: IIF1MConstantCache
    tmp = expm(A*dt)*(uprev + integrator.g(uprev,p,t)*W.dW)
  elseif typeof(cache) <: IIF2MConstantCache
    tmp = expm(A*dt)*(uprev + 0.5dt*integrator.f[2](uprev,p,t) + integrator.g(uprev,p,t)*W.dW)
  end

  if integrator.iter > 1 && !integrator.u_modified
    uhold[1] = current_extrapolant(t+dt,integrator)
  end # else uhold is previous value.

  rhs.t = t
  rhs.dt = dt
  rhs.tmp = tmp
  nlres = alg.nlsolve(nl_rhs,uhold)

  u = nlres[1]
  integrator.u = u
end

mutable struct RHS_IIF1{F,uType,tType,DiffCacheType,SizeType,P} <: Function
  f::F
  tmp::uType
  t::tType
  dt::tType
  dual_cache::DiffCacheType
  sizeu::SizeType
  p::P
end
function (f::RHS_IIF1)(resid,u)
  _du = get_du(f.dual_cache, eltype(u))
  du = reinterpret(eltype(u),_du)
  f.f[2](du,reshape(u,f.sizeu),f.p,f.t+f.dt)
  #@. resid = u - p.tmp - p.dt*du
  @tight_loop_macros for i in eachindex(u)
    @inbounds resid[i] = u[i] - f.tmp[i] - f.dt*du[i]
  end
end

mutable struct RHS_IIF2{F,uType,tType,DiffCacheType,SizeType,P} <: Function
  f::F
  tmp::uType
  t::tType
  dt::tType
  dual_cache::DiffCacheType
  sizeu::SizeType
  p::P
end
function (f::RHS_IIF2)(resid,u)
  _du = get_du(f.dual_cache, eltype(u))
  du = reinterpret(eltype(u),_du)
  f.f[2](du,reshape(u,f.sizeu),f.p,f.t+f.dt)
  #@. resid = u - p.tmp - 0.5p.dt*du
  @tight_loop_macros for i in eachindex(u)
    @inbounds resid[i] = u[i] - f.tmp[i] - 0.5f.dt*du[i]
  end
end

@muladd function perform_step!(integrator,cache::Union{IIF1MCache,IIF2MCache},f=integrator.f)
  @unpack rtmp1,rtmp2,rtmp3,tmp,noise_tmp = cache
  @unpack uhold,rhs,nl_rhs = cache
  @unpack t,dt,uprev,u,W,p = integrator
  alg = typeof(integrator.alg) <: StochasticDiffEqCompositeAlgorithm ? integrator.alg.algs[integrator.alg.current_alg] : integrator.alg
  uidx = eachindex(u)

  integrator.g(rtmp2,uprev,p,t)

  if is_diagonal_noise(integrator.sol.prob)
    scale!(rtmp2,W.dW) # rtmp2 === rtmp3
  else
    A_mul_B!(rtmp3,rtmp2,W.dW)
  end

  rtmp3 .+= uprev

  if typeof(cache) <: IIF2MCache
    integrator.f[2](rtmp1,uprev,p,t)
    @. rtmp3 = @muladd 0.5dt*rtmp1 + rtmp3
  end

  A = integrator.f[1](rtmp1,uprev,p,t)
  M = expm(A*dt)
  A_mul_B!(tmp,M,rtmp3)

  if integrator.iter > 1 && !integrator.u_modified
    current_extrapolant!(uhold,t+dt,integrator)
  end # else uhold is previous value.

  rhs.t = t
  rhs.dt = dt
  rhs.tmp = tmp
  rhs.sizeu = size(u)
  nlres = alg.nlsolve(nl_rhs,uhold)

  copy!(uhold,nlres)


end

@muladd function perform_step!(integrator,cache::IIF1MilCache,f=integrator.f)
  @unpack rtmp1,rtmp2,rtmp3,tmp,noise_tmp = cache
  @unpack uhold,rhs,nl_rhs = cache
  @unpack t,dt,uprev,u,W,p = integrator
  alg = typeof(integrator.alg) <: StochasticDiffEqCompositeAlgorithm ? integrator.alg.algs[integrator.alg.current_alg] : integrator.alg

  dW = W.dW; sqdt = integrator.sqdt
  f = integrator.f; g = integrator.g

  A = integrator.f[1](t,uprev,rtmp1)
  M = expm(A*dt)

  uidx = eachindex(u)
  integrator.g(rtmp2,uprev,p,t)
  if typeof(cache) <: Union{IIF1MCache,IIF2MCache}
    if is_diagonal_noise(integrator.sol.prob)
      scale!(rtmp2,W.dW) # rtmp2 === rtmp3
    else
      A_mul_B!(rtmp3,rtmp2,W.dW)
    end
  else #Milstein correction
    rtmp2 = M*rtmp2 # A_mul_B!(rtmp2,M,gtmp)
    @unpack gtmp,gtmp2 = cache
    #error("Milstein correction does not work.")
    A_mul_B!(rtmp3,rtmp2,W.dW)
    I = zeros(length(dW),length(dW));
    Dg = zeros(length(dW),length(dW)); mil_correction = zeros(length(dW))
    mil_correction .= 0.0
    for i=1:length(dW),j=1:length(dW)
        I[j,i] = 0.5*dW[i]*dW[j]
        j == i && (I[i,i] -= 0.5*dt) # Ito correction
    end
    for j = 1:length(uprev)
      #Kj = uprev .+ dt.*du1 + sqdt*rtmp2[:,j] # This works too
      Kj = uprev .+ sqdt*rtmp2[:,j]
      g(gtmp,Kj,p,t); A_mul_B!(gtmp2,M,gtmp)
      Dgj = (gtmp2 - rtmp2)/sqdt
      mil_correction .+= Dgj*I[:,j]
    end
    rtmp3 .+= mil_correction
  end

  if typeof(cache) <: IIF2MCache
    integrator.f[2](t,uprev,rtmp1)
    @. rtmp1 = @muladd 0.5dt*rtmp1 + uprev + rtmp3
    A_mul_B!(tmp,M,rtmp1)
  elseif !(typeof(cache) <: IIF1MilCache)
    @. rtmp1 = uprev + rtmp3
    A_mul_B!(tmp,M,rtmp1)
  else
    A_mul_B!(tmp,M,uprev)
    tmp .+= rtmp3
  end

  if integrator.iter > 1 && !integrator.u_modified
    current_extrapolant!(uhold,t+dt,integrator)
  end # else uhold is previous value.

  rhs.t = t
  rhs.dt = dt
  rhs.tmp = tmp
  rhs.sizeu = size(u)
  nlres = alg.nlsolve(nl_rhs,uhold)

  copy!(uhold,nlres)
end
