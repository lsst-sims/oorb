!====================================================================!
!                                                                    !
! Copyright 2002-2018,2019                                           !
! Mikael Granvik, Jenni Virtanen, Karri Muinonen, Teemu Laakso,      !
! Dagmara Oszkiewicz                                                 !
!                                                                    !
! This file is part of OpenOrb.                                      !
!                                                                    !
! OpenOrb is free software: you can redistribute it and/or modify it !
! under the terms of the GNU General Public License as published by  !
! the Free Software Foundation, either version 3 of the License, or  !
! (at your option) any later version.                                !
!                                                                    !
! OpenOrb is distributed in the hope that it will be useful, but     !
! WITHOUT ANY WARRANTY; without even the implied warranty of         !
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU  !
! General Public License for more details.                           !
!                                                                    !
! You should have received a copy of the GNU General Public License  !
! along with OpenOrb. If not, see <http://www.gnu.org/licenses/>.    !
!                                                                    !
!====================================================================!
!
!! *Module*description*:
!!
!! Contains integrators, force routines, and a universal Kepler
!! solver.
!!
!! @author  TL, MG, JV
!! @version 2019-08-23
!!
MODULE integrators

  USE planetary_data
  USE linal

  IMPLICIT NONE
  PRIVATE

  !! High precicion real type for integration variables.
  INTEGER, PARAMETER :: prec = rprec8
  !! Value of pi (32 digits).
  REAL(prec), PARAMETER :: pi = 3.14159265358979323846264338327950_prec
  !! Value of 2*pi (32 digits).
  REAL(prec), PARAMETER :: two_pi = 2.0_prec*pi
  !! Gaussian gravitational constant.
  REAL(prec), PARAMETER :: ggc = 0.01720209895_prec
  !! Newtonian gravitational constant.
  REAL(prec), PARAMETER :: gc = ggc**2
  !! Speed of light (AU/day).
  REAL(prec), PARAMETER :: c = 173.14463272_prec
  REAL(prec), PARAMETER :: ic2 = 1.0_prec/c**2
  !! Decimal precision.
  REAL(prec), PARAMETER :: rstep_tol = 10*EPSILON(pi)
  !! Decimal precision for extrapolation (or step convergence).
  REAL(prec), PARAMETER :: bs_extrapol_tol = 10*EPSILON(pi)
  !! Default step length (1 days):
  REAL(prec), PARAMETER :: step_def = 1.0_prec
  !! Sequence of substeps (Bulirsch and Stoer).
  INTEGER, PARAMETER :: nseq = 27
  INTEGER, DIMENSION(nseq), PARAMETER :: &
       seq = (/ 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, &
       256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, &
       12288, 16384, 24576 /) ! n_i = 2 * n_(i-2)
  ! Maximum number of asteroid perturbers available
  INTEGER :: nastpert = 300

  LOGICAL :: relativity = .TRUE.
  ! Default central body for the dynamical system
  INTEGER, PARAMETER :: central_body_prm = 11
  INTEGER :: central_body

  ! NOTE: central_body should be an input argument in all
  ! the public routines, since from thereon it is currently
  ! passed on as an global module parameter.
  PUBLIC :: kepler_step
  PUBLIC :: bulirsch_full_jpl
  PUBLIC :: gauss_radau_15_full_jpl
  PUBLIC :: set_relativity

  INTERFACE ratf_extrapolation
     MODULE PROCEDURE ratf_extrapolation_vec, ratf_extrapolation_mat, &
          ratf_extrapolation_vec_n, ratf_extrapolation_mat_n
  END INTERFACE ratf_extrapolation

  INTERFACE polf_extrapolation
     MODULE PROCEDURE polf_extrapolation_vec, polf_extrapolation_mat, &
          polf_extrapolation_vec_n, polf_extrapolation_mat_n
  END INTERFACE polf_extrapolation

CONTAINS





  !! Description:
  !!   Bulirsch-Stoer scheme.
  !!   Rational function extrapolation w/ modified midpoint.
  !!
  !! References:
  !!   [1] Press et al. 1989, Numerical Recipes.
  !!   [2] Stoer & Bulirsch 1980, Introduction to Num. Anal.
  !!
  !! Usage:
  !!   CALL bulirsch_full_jpl(mjd_tdt0, mjd_tdt1, &
  !!                          celements, error, jacobian, step)
  !!
  !! mjd_tdt0         integration start (MJD TT)
  !! mjd_tdt1         integration stop (MJD TT)
  !! celements        initial coordinates for massless particles (1:6,1:nparticles)
  !! error            returns true, if something fails
  !! jacobian         jacobian matrix (coordinates wrt initial coordinates)
  !! step             step size
  !! ncenter          number of solar-system object to use as center (default=Sun)
  !! encounters       table containing the closest distances to, or earliest
  !!                  time of impact with solar-system objects
  !! masses           masses for additional perturbing bodies
  !!
  SUBROUTINE bulirsch_full_jpl(mjd_tdt0, mjd_tdt1, celements, &
       perturbers, asteroid_perturbers, error, jacobian, step, ncenter, encounters, &
       masses, info_verb, radial_acceleration)

    REAL(prec), INTENT(in)                                :: mjd_tdt0, mjd_tdt1
    REAL(prec), DIMENSION(:,:), INTENT(inout)             :: celements
    LOGICAL, DIMENSION(:), INTENT(in)                     :: perturbers
    LOGICAL, INTENT(in)                                   :: asteroid_perturbers
    LOGICAL, INTENT(inout)                                :: error
    REAL(prec), DIMENSION(:,:,:), INTENT(inout), OPTIONAL :: jacobian
    REAL(prec), INTENT(in), OPTIONAL                      :: step
    INTEGER,  INTENT(in), OPTIONAL                        :: ncenter
    REAL(prec), DIMENSION(:,:,:), INTENT(out), OPTIONAL   :: encounters
    REAL(prec), DIMENSION(:), INTENT(in), OPTIONAL        :: masses
    INTEGER, INTENT(in), OPTIONAL                         :: info_verb
    REAL(prec), INTENT(in), OPTIONAL                      :: radial_acceleration

    REAL(prec), DIMENSION(:,:,:), ALLOCATABLE :: pws, encounters_
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: ws
    REAL(prec) :: mjd_tdt, tmp, istep, rstep
    INTEGER    :: i, j, k, m, n, total, err

    ! The 'masses' variable refers to masses of additional
    ! massive objects that need to be integrated and act as pertubers
    ! for the massless particles. The orbital elements of the
    ! additional perturbers are concatenated to the end of
    ! 'celements'. Note that the particles are treated asymmetrically:
    ! massless particles are not affecting the other particles (how
    ! could they?) and additional massive particles are only affecting
    ! the massless particles. In particular, ephemeris for planets and
    ! large asteroids originating in de405 are not affected by the
    ! additional massive particles.

    ALLOCATE(ws(6,SIZE(celements,dim=2)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       WRITE(0,"(A)") "bulirsch_full_jpl: Could not allocate memory (5)."
       RETURN
    END IF
    ws(:,1:SIZE(celements,dim=2)) = celements

    IF (PRESENT(jacobian)) THEN
       ALLOCATE(pws(SIZE(jacobian,dim=1),SIZE(jacobian,dim=2), &
            SIZE(jacobian,dim=3)), stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: Could not allocate memory (10)."
          DEALLOCATE(ws, pws, stat=err)
          RETURN
       END IF
    END IF

    ! Reset the global module parameter
    IF (PRESENT(ncenter)) THEN
       central_body = ncenter
    ELSE
       central_body = central_body_prm
    END IF

    ! Initialize the encounter table
    IF (PRESENT(encounters)) THEN
       IF (SIZE(encounters,dim=1) < SIZE(ws,dim=2)) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: 'encounters' array too small (1)."
          RETURN
       END IF
       IF (SIZE(encounters,dim=2) < 11) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: 'encounters' array too small (2)."
          RETURN
       END IF
       IF (SIZE(encounters,dim=3) < 4) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: 'encounters' array too small (3)."
          RETURN
       END IF
       encounters = HUGE(encounters)
       encounters(:,:,2) = 3
       ALLOCATE(encounters_(SIZE(encounters,dim=1),SIZE(encounters,dim=2),SIZE(encounters,dim=3)))
    END IF

    ! Set integration parameters.
    tmp = mjd_tdt1 - mjd_tdt0
    IF (PRESENT(step)) THEN
       istep = SIGN(step,tmp)
    ELSE
       ! Use default step length:
       istep = SIGN(step_def,tmp)
    END IF
    total = ABS(INT(tmp/istep))
    !rstep = SIGN(MOD(tmp,istep),tmp)
    rstep = tmp - total*istep

    IF (ABS(rstep) > ABS(istep)) THEN
       WRITE(0,*) "There appears to be a problem with the " // &
            "selection of # of steps in the BS integrator. " // &
            "Please send the lines below to MG for analysis."
       WRITE(0,*) "mjd_tdt0:    ", mjd_tdt0
       WRITE(0,*) "mjd_tdt1:    ", mjd_tdt1
       WRITE(0,*) "tmp:         ", tmp
       WRITE(0,*) "istep:       ", istep
       WRITE(0,*) "rstep:       ", rstep
       WRITE(0,*) "total:       ", total
       WRITE(0,*) "total*istep: ", total*istep
       STOP
    END IF

    ! Integration loop
    k       = 1
    mjd_tdt = mjd_tdt0
    IF (info_verb >= 4) THEN
       DO i=1,SIZE(ws,dim=2)
          WRITE(*,"(A,I0,1X,A,1X,F15.5,6(1X,F20.15))") "Orbit #", &
               i, "at epoch", mjd_tdt0, ws(:,i)
       END DO
    END IF
    IF (PRESENT(jacobian)) THEN
       pws = jacobian
       DO WHILE (k <= total)
          IF (PRESENT(encounters)) THEN
             CALL step_bulirsch_full_jpl(mjd_tdt, istep, perturbers, asteroid_perturbers,ws, &
                  ws, error, pws, pws, encounters=encounters_, masses=masses, &
                  radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL step_bulirsch_full_jpl(mjd_tdt, istep, perturbers, asteroid_perturbers,ws, &
                  ws, error, pws, pws, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          IF (error) THEN
             DEALLOCATE(ws, pws, stat=err)
             WRITE(0,"(A)") "bulirsch_full_jpl: TRACE BACK (5)"
             RETURN
          END IF
          mjd_tdt = mjd_tdt0 + k * istep
          k       = k + 1
          IF (info_verb >= 4) THEN
             DO i=1,SIZE(ws,dim=2)
                WRITE(*,"(A,I0,1X,A,1X,F15.5,6(1X,F20.15))") "Orbit #", &
                     i, "at epoch", mjd_tdt, ws(:,i)
             END DO
          END IF
       END DO

       IF (ABS(rstep) > rstep_tol) THEN
          IF (PRESENT(encounters)) THEN
             CALL step_bulirsch_full_jpl(mjd_tdt, rstep, perturbers, asteroid_perturbers,ws, &
                  ws, error, pws, pws, encounters=encounters_, masses=masses, &
                  radial_acceleration=radial_acceleration)
          ELSE
             CALL step_bulirsch_full_jpl(mjd_tdt, rstep, perturbers, asteroid_perturbers, ws, &
                  ws, error, pws, pws, masses=masses, radial_acceleration=radial_acceleration)
          END IF
       ELSE
          IF (PRESENT(encounters)) THEN
             CALL step_midpoint_full_jpl(mjd_tdt, rstep, 10, perturbers, asteroid_perturbers, &
                  ws, ws, error, pws, pws, encounters=encounters_, &
                  masses=masses, radial_acceleration=radial_acceleration)
          ELSE
             CALL step_midpoint_full_jpl(mjd_tdt, rstep, 10, perturbers, asteroid_perturbers,&
                  ws, ws, error, pws, pws, masses=masses, radial_acceleration=radial_acceleration)
          END IF
       END IF
       IF (PRESENT(encounters)) THEN
          ! Log closest non-impacting encounter during the integration step
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
             encounters(m,n,:) = encounters_(m,n,:)
          END FORALL
          ! Log earliest time of impact during the integration step
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
               encounters_(m,n,1) < encounters(m,n,1))
             encounters(m,n,:) = encounters_(m,n,:)
          END FORALL
       END IF
       celements = ws
       jacobian  = pws
       DEALLOCATE(pws, stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: Could not deallocate memory (5)."
          RETURN
       END IF
    ELSE
       DO WHILE (k <= total)
          IF (PRESENT(encounters)) THEN
             CALL step_bulirsch_full_jpl(mjd_tdt, istep, perturbers, asteroid_perturbers, ws, &
                  ws, error, encounters=encounters_, masses=masses, &
                  radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL step_bulirsch_full_jpl(mjd_tdt, istep, perturbers, asteroid_perturbers, ws, &
                  ws, error, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          IF (error) THEN
             DEALLOCATE(ws, stat=err)
             WRITE(0,"(A)") "bulirsch_full_jpl: TRACE BACK (10)"
             RETURN
          END IF
          mjd_tdt = mjd_tdt0 + k * istep
          k       = k + 1
          IF (info_verb >= 4) THEN
             DO i=1,SIZE(ws,dim=2)
                WRITE(*,"(A,I0,1X,A,1X,F15.5,6(1X,F20.15))") "Orbit #", &
                     i, "at epoch", mjd_tdt, ws(:,i)
             END DO
          END IF
       END DO
       IF (ABS(rstep) > rstep_tol) THEN
          IF (PRESENT(encounters)) THEN
             CALL step_bulirsch_full_jpl(mjd_tdt, rstep, perturbers, asteroid_perturbers, ws, &
                  ws, error, encounters=encounters_, masses=masses, &
                  radial_acceleration=radial_acceleration)
          ELSE
             CALL step_bulirsch_full_jpl(mjd_tdt, rstep, perturbers, asteroid_perturbers, ws, &
                  ws, error, masses=masses, radial_acceleration=radial_acceleration)
          END IF
       ELSE
          IF (PRESENT(encounters)) THEN
             CALL step_midpoint_full_jpl(mjd_tdt, rstep, 10, perturbers, asteroid_perturbers,&
                  ws, ws, error, encounters=encounters_, &
                  masses=masses, radial_acceleration=radial_acceleration)
          ELSE
             CALL step_midpoint_full_jpl(mjd_tdt, rstep, 10, perturbers, asteroid_perturbers,&
                  ws, ws, error, masses=masses, radial_acceleration=radial_acceleration)
          END IF
       END IF
       IF (PRESENT(encounters)) THEN
          ! Log closest non-impacting encounter during the integration step
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
             encounters(m,n,:) = encounters_(m,n,:)
          END FORALL
          ! Log earliest time of impact during the integration step
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
               encounters_(m,n,1) < encounters(m,n,1))
             encounters(m,n,:) = encounters_(m,n,:)
          END FORALL
       END IF
       celements = ws
    END IF
    IF (info_verb >= 4) THEN
       DO i=1,SIZE(ws,dim=2)
          WRITE(*,"(A,I0,1X,A,1X,F15.5,6(1X,F20.15))") "Orbit #", &
               i, "at epoch", mjd_tdt1, ws(:,i)
       END DO
    END IF
    DEALLOCATE(ws, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       WRITE(0,"(A)") "bulirsch_full_jpl: Could not deallocate memory (10)."
       RETURN
    END IF
    IF (PRESENT(encounters)) THEN
       DEALLOCATE(encounters_, stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "bulirsch_full_jpl: Could not deallocate memory (15)."
          RETURN
       END IF
    END IF

  END SUBROUTINE bulirsch_full_jpl





  !! One integration step.
  !!
  !!  mjd_tdt  modified Julian date (for ephemerides)
  !!  H        step size
  !!  ws0      initial coordinates for the massless bodies
  !!  ws1      final coordinates for the massless bodies
  !!  error    returns true, if something fails
  !!  pws0     initial values of the partial derivatives
  !!  pws1     final values of the partial derivatives
  !!
  SUBROUTINE step_bulirsch_full_jpl(mjd_tdt, H, perturbers, asteroid_perturbers,ws0, ws1, &
       error, pws0, pws1, encounters, masses, radial_acceleration)

    REAL(prec), INTENT(in)                                :: mjd_tdt, H
    LOGICAL, DIMENSION(:), INTENT(in)                     :: perturbers
    LOGICAL, INTENT(in)                                   :: asteroid_perturbers
    REAL(prec), DIMENSION(:,:), INTENT(inout)             :: ws0, ws1
    LOGICAL, INTENT(inout)                                :: error
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(inout) :: pws0, pws1
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(out)   :: encounters
    REAL(prec), DIMENSION(:), OPTIONAL, INTENT(in)        :: masses
    REAL(prec), INTENT(in), OPTIONAL                      :: radial_acceleration

    REAL(prec), DIMENSION(:,:,:,:,:), ALLOCATABLE :: pddif
    REAL(prec), DIMENSION(:,:,:,:), ALLOCATABLE :: pwa0, pwa1, ddif
    REAL(prec), DIMENSION(:,:,:), ALLOCATABLE :: wa0, wa1, pwst, encounters_
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: wst
    REAL(prec), DIMENSION(:), ALLOCATABLE :: hseq
    INTEGER, DIMENSION(:), ALLOCATABLE :: ws_index, pws_index
    INTEGER :: ws_final, pws_final, i, k, l, m, n, NS, err
    LOGICAL, DIMENSION(:), ALLOCATABLE :: ws_converged, pws_converged

    ALLOCATE(hseq(SIZE(seq)), &
         wa0(6,SIZE(seq),SIZE(ws0,dim=2)), &
         wa1(6,SIZE(seq),SIZE(ws0,dim=2)), &
         ddif(6,SIZE(seq),SIZE(seq),SIZE(ws0,dim=2)), &
         wst(6,SIZE(ws0,dim=2)), &
         ws_converged(SIZE(ws0,dim=2)), &
         ws_index(SIZE(ws0,dim=2)), &
         stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       WRITE(0,"(A)") "step_bulirsch_full_jpl: Could not allocate memory (5)."
       DEALLOCATE(hseq, wa0, wa1, pwa0, pwa1, ddif, pddif, wst, &
            pwst, ws_converged, pws_converged, ws_index, pws_index, &
            stat=err)
       RETURN
    END IF
    ws_index = 0
    ws_converged = .FALSE.

    IF (PRESENT(encounters)) THEN
       ALLOCATE(encounters_(SIZE(encounters,dim=1),SIZE(encounters,dim=2),SIZE(encounters,dim=3)))
       encounters = HUGE(encounters)
       encounters(:,:,2) = 3
    END IF

    IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
       ALLOCATE(pwa0(6,SIZE(seq),6,SIZE(ws0,dim=2)), &
            pwa1(6,SIZE(seq),6,SIZE(ws0,dim=2)), &
            pddif(6,SIZE(seq),SIZE(seq),6,SIZE(ws0,dim=2)), &
            pwst(6,6,SIZE(ws0,dim=2)), &
            pws_converged(SIZE(ws0,dim=2)), &
            pws_index(SIZE(ws0,dim=2)), &
            stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "step_bulirsch_full_jpl: Could not allocate memory (10)."
          DEALLOCATE(hseq, wa0, wa1, pwa0, pwa1, ddif, pddif, wst, &
               pwst, ws_converged, pws_converged, ws_index, &
               pws_index, stat=err)
          RETURN
       END IF
       pws_index = 0
       pws_converged = .FALSE.
    END IF

    ws_final = 0
    pws_final = 0
    NS = SIZE(ws0,dim=2)

    DO i=1, nseq

       hseq(i) = (H / seq(i)) ** 2

       ! Integration with seq(i) substeps.
       IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
          IF (PRESENT(encounters)) THEN
             CALL step_midpoint_full_jpl(mjd_tdt, H, seq(i), perturbers, asteroid_perturbers, &
                  ws0, wst, error, pws0, pwst, encounters=encounters_, &
                  masses=masses, radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL step_midpoint_full_jpl(mjd_tdt, H, seq(i), perturbers, asteroid_perturbers, &
                  ws0, wst, error, pws0, pwst, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          DO k=1, NS
             wa0(:,i,k) = wst(:,k)
             DO l=1, 6
                pwa0(:,i,l,k) = pwst(:,l,k)
             END DO
          END DO
       ELSE
          IF (PRESENT(encounters)) THEN
             CALL step_midpoint_full_jpl(mjd_tdt, H, seq(i), perturbers, asteroid_perturbers,&
                  ws0, wst, error, encounters=encounters_, masses=masses, &
                  radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL step_midpoint_full_jpl(mjd_tdt, H, seq(i), perturbers, asteroid_perturbers,&
                  ws0, wst, error, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          DO k=1, NS
             wa0(:,i,k) = wst(:,k)
          END DO
       END IF
       IF (error) THEN
          WRITE(0,"(A)") "step_bulirsch_full_jpl: TRACE BACK (5)."
          DEALLOCATE(hseq, wa0, wa1, pwa0, pwa1, ddif, pddif, wst, &
               pwst, ws_converged, pws_converged, ws_index, pws_index, &
               stat=err)
          RETURN
       END IF

       ! Fill in the extrapolation table and check for convergence.
       IF (ws_final == 0) THEN
          CALL polf_extrapolation(i, hseq, wa0, wa1, ddif, ws_converged, error)
          !          CALL ratf_extrapolation(i, hseq, wa0, wa1, ddif, ws_converged, error)
          IF (error) THEN
             WRITE(0,"(A)") "step_bulirsch_full_jpl: TRACE BACK (10)."
             DEALLOCATE(hseq, wa0, wa1, pwa0, pwa1, ddif, pddif, wst, &
                  pwst, ws_converged, pws_converged, ws_index, pws_index, &
                  stat=err)
             RETURN
          END IF
          WHERE (ws_converged .AND. ws_index == 0)
             ws_index = i
          END WHERE
          IF (ALL(ws_index > 0)) THEN
             ws_final = i
          END IF
       END IF
       IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
          IF (pws_final == 0) THEN
             CALL polf_extrapolation(i, hseq, pwa0, pwa1, pddif, pws_converged, error)
             !             CALL ratf_extrapolation(i, hseq, pwa0, pwa1, pddif, pws_converged, error)
             IF (error) THEN
                WRITE(0,"(A)") "step_bulirsch_full_jpl: TRACE BACK (15)."
                DEALLOCATE(hseq, wa0, wa1, pwa0, pwa1, ddif, pddif, wst, &
                     pwst, ws_converged, pws_converged, ws_index, pws_index, &
                     stat=err)
                RETURN
             END IF
             WHERE (pws_converged .AND. pws_index == 0)
                pws_index = i
             END WHERE
             IF (ALL(pws_index > 0)) THEN
                pws_final = i
             END IF
          END IF
       ELSE
          pws_final = 1
       END IF
       IF (ws_final /= 0 .AND. pws_final /= 0) THEN
          EXIT
       END IF

    END DO

    ! If there were problems with convergence.
    IF (ws_final == 0) THEN
       ws_final = nseq
       DO k=1, NS
          IF (ws_index(k) == 0) THEN
             ! Error report
             ws_index(k) = nseq
          END IF
       END DO
    END IF
    IF (pws_final == 0) THEN
       pws_final = nseq
       DO k=1, NS
          IF (pws_index(k) == 0) THEN
             ! Error report
             pws_index(k) = nseq
          END IF
       END DO
    END IF

    IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
       DO k=1, NS
          ws1(:,k) = wa1(:,ws_index(k),k)
          DO l=1, 6
             pws1(:,l,k) = pwa1(:,pws_index(k),l,k)
          END DO
       END DO
    ELSE
       DO k=1, NS
          ws1(:,k) = wa1(:,ws_index(k),k)
       END DO
    END IF

    DEALLOCATE(hseq, wa0, wa1, ddif, wst, ws_converged, ws_index, &
         stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       WRITE(0,"(A)") "step_bulirsch_full_jpl: Could not deallocate memory (5)."
       RETURN
    END IF
    IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
       DEALLOCATE(pwa0, pwa1, pddif, pwst, pws_converged, pws_index, &
            stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "step_bulirsch_full_jpl: Could not deallocate memory (10)."
          RETURN
       END IF
    END IF
    IF (PRESENT(encounters)) THEN
       DEALLOCATE(encounters_, stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "step_bulirsch_full_jpl: Could not deallocate memory (15)."
          RETURN
       END IF
    END IF

  END SUBROUTINE step_bulirsch_full_jpl






  !! Description:
  !!   Modified midpoint step (2nd order).
  !!
  !! References:
  !!   [1] Press et al. 1989, Numerical Recipes.
  !!
  !! Usage:
  !!   CALL step_midpoint_full_jpl(mjd_tdt, h, nsteps, ws0, ws1,
  !!                               error, pws0, pws1)
  !!
  !! One integration step.
  !!
  !!  mjd_tdt  modified Julian date (for ephemerides)
  !!  h        (big) step size
  !!  nsteps   number of substeps
  !!  ws0      initial coordinates for the massless bodies
  !!  ws1      final coordinates for the massless bodies
  !!  error    returns true, if something fails
  !!  pws0     initial values of the partial derivatives
  !!  pws1     final values of the partial derivatives
  !!
  SUBROUTINE step_midpoint_full_jpl(mjd_tdt, h, nsteps, perturbers, asteroid_perturbers,&
       ws0, ws1, error, pws0, pws1, encounters, masses, radial_acceleration)

    REAL(prec), INTENT(in)                                :: mjd_tdt, h
    INTEGER, INTENT(in)                                   :: nsteps
    LOGICAL, DIMENSION(:), INTENT(in)                     :: perturbers
    LOGICAL, INTENT(in)                                   :: asteroid_perturbers
    REAL(prec), DIMENSION(:,:), INTENT(inout)             :: ws0, ws1
    LOGICAL, INTENT(inout)                                :: error
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(inout) :: pws0, pws1
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(out)   :: encounters
    REAL(prec), DIMENSION(:), OPTIONAL, INTENT(in)        :: masses
    REAL(prec), INTENT(in), OPTIONAL                      :: radial_acceleration

    INTEGER               :: err, i, k, m, n, NS
    INTEGER, DIMENSION(2) :: sw
    REAL(prec)            :: dt

    REAL(prec), DIMENSION(6,SIZE(ws0,dim=2),2)   :: q
    REAL(prec), DIMENSION(6,SIZE(ws0,dim=2))     :: qd
    REAL(prec), DIMENSION(6,6,SIZE(ws0,dim=2),2) :: pq
    REAL(prec), DIMENSION(6,6,SIZE(ws0,dim=2))   :: pqd
    REAL(prec), DIMENSION(:,:,:), ALLOCATABLE    :: encounters_

    REAL(prec), DIMENSION(6,6) :: pqt

    NS = SIZE(ws0,dim=2)

    ! Substep size.
    dt = h / nsteps

    ! Algorithm needs information from two previous points.
    ! When calculating at k+1, sw(1) points to variables at k-1,
    ! and sw(2) to variables at k.
    sw(1)         = 1
    sw(2)         = 2
    q(:,:,sw(1))  = ws0
    IF (PRESENT(encounters)) THEN
       ALLOCATE(encounters_(SIZE(encounters,dim=1), &
            SIZE(encounters,dim=2), SIZE(encounters,dim=3)), stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "step_midpoint_full_jpl: Could not allocate memory (5)."
          RETURN
       END IF
       encounters = 0.0_prec
       encounters(:,:,2) = 3
    END IF

    ! If partial derivatives are needed.
    IF (PRESENT(pws0) .AND. PRESENT(pws1)) THEN
       pq(:,:,:,sw(1)) = pws0
       IF (PRESENT(encounters)) THEN
          CALL interact_full_jpl(q(:,:,sw(1)), mjd_tdt, perturbers, asteroid_perturbers, &
               qd, error, pqd, encounters=encounters_, masses=masses, &
               radial_acceleration=radial_acceleration)
          ! Initialize log
          encounters = encounters_
          encounters(:,:,4) = dt
       ELSE
          CALL interact_full_jpl(q(:,:,sw(1)), mjd_tdt, perturbers, asteroid_perturbers, &
               qd, error, pqd, masses=masses, radial_acceleration=radial_acceleration)
       END IF
       IF (error) THEN
          RETURN
       END IF
       q(:,:,sw(2)) = q(:,:,sw(1)) + dt * qd
       DO i=1, NS
          pqt = MATMUL(pqd(:,:,i),pq(:,:,i,sw(1)))
          pq(:,:,i,sw(2)) = pq(:,:,i,sw(1)) + dt * pqt
       END DO
       DO k=2, nsteps
          IF (PRESENT(encounters)) THEN
             CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + (k - 1) * dt, &
                  perturbers, asteroid_perturbers, qd, error, pqd, encounters=encounters_, &
                  masses=masses, radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration substep
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,1:3) = encounters_(m,n,1:3)
             END FORALL
             ! Log earliest time of impact during the integration substep
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters_(m,n,2)) == 1 .AND. encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,1:3) = encounters_(m,n,1:3)
             END FORALL
          ELSE
             CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + (k - 1) * dt, &
                  perturbers, asteroid_perturbers, qd, error, pqd, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          IF (error) THEN
             RETURN
          END IF
          q(:,:,sw(1)) = q(:,:,sw(1)) + 2.0_prec * dt * qd
          DO i = 1, NS
             pqt = MATMUL(pqd(:,:,i),pq(:,:,i,sw(2)))
             pq(:,:,i,sw(1)) = pq(:,:,i,sw(1)) + 2.0_prec * dt * pqt
          END DO
          sw(1:2) = sw(2:1:-1)
       END DO
       IF (PRESENT(encounters)) THEN
          CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + h, perturbers, asteroid_perturbers,&
               qd, error, pqd, encounters=encounters_, masses=masses, &
               radial_acceleration=radial_acceleration)
          ! Log closest non-impacting encounter during the integration substep
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
             encounters(m,n,1:3) = encounters_(m,n,1:3)
          END FORALL
          ! Log earliest time of impact during the integration substep
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters_(m,n,2)) == 1 .AND. encounters_(m,n,1) < encounters(m,n,1))
             encounters(m,n,1:3) = encounters_(m,n,1:3)
          END FORALL
       ELSE
          CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + h, perturbers, asteroid_perturbers,&
               qd, error, pqd, masses=masses, radial_acceleration=radial_acceleration)
       END IF
       IF (error) THEN
          RETURN
       END IF
       q(:,:,sw(1)) = q(:,:,sw(1)) + dt * qd
       DO i=1, NS
          pqt = MATMUL(pqd(:,:,i),pq(:,:,i,sw(2)))
          pq(:,:,i,sw(1)) = pq(:,:,i,sw(1)) + dt * pqt
       END DO
       ws1  = (q(:,:,sw(1)) + q(:,:,sw(2))) / 2.0_prec
       pws1 = (pq(:,:,:,sw(1)) + pq(:,:,:,sw(2))) / 2.0_prec
    ELSE
       ! Plain integration.
       IF (PRESENT(encounters)) THEN
          CALL interact_full_jpl(q(:,:,sw(1)), mjd_tdt, perturbers,asteroid_perturbers, &
               qd, error, encounters=encounters_, masses=masses, &
               radial_acceleration=radial_acceleration)
          ! Initialize log
          encounters(:,:,1:3) = encounters_(:,:,1:3)
          encounters(:,:,4) = dt
       ELSE
          CALL interact_full_jpl(q(:,:,sw(1)), mjd_tdt, perturbers, asteroid_perturbers,&
               qd, error, masses=masses, radial_acceleration=radial_acceleration)
       END IF
       IF (error) THEN
          RETURN
       END IF
       q(:,:,sw(2)) = q(:,:,sw(1)) + dt * qd
       DO k=2, nsteps
          IF (PRESENT(encounters)) THEN
             CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + (k - 1) * dt, &
                  perturbers, asteroid_perturbers,qd, error, encounters=encounters_, &
                  masses=masses, radial_acceleration=radial_acceleration)
             ! Log closest non-impacting encounter during the integration substep
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,1:3) = encounters_(m,n,1:3)
             END FORALL
             ! Log earliest time of impact during the integration substep
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters_(m,n,2)) == 1 .AND. encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,1:3) = encounters_(m,n,1:3)
             END FORALL
          ELSE
             CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + (k - 1) * dt, &
                  perturbers, asteroid_perturbers, qd, error, masses=masses, radial_acceleration=radial_acceleration)
          END IF
          IF (error) THEN
             RETURN
          END IF
          q(:,:,sw(1)) = q(:,:,sw(1)) + 2.0_prec * dt * qd
          sw(1:2)      = sw(2:1:-1)
       END DO
       IF (PRESENT(encounters)) THEN
          CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + h, perturbers, asteroid_perturbers,&
               qd, error, encounters=encounters_, masses=masses, &
               radial_acceleration=radial_acceleration)
          ! Log closest non-impacting encounter during the integration substep
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
             encounters(m,n,1:3) = encounters_(m,n,1:3)
          END FORALL
          ! Log earliest time of impact during the integration substep
          FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
               NINT(encounters_(m,n,2)) == 1 .AND. encounters_(m,n,1) < encounters(m,n,1))
             encounters(m,n,1:3) = encounters_(m,n,1:3)
          END FORALL
       ELSE
          CALL interact_full_jpl(q(:,:,sw(2)), mjd_tdt + h, perturbers, asteroid_perturbers, &
               qd, error, masses=masses, radial_acceleration=radial_acceleration)
       END IF
       IF (error) THEN
          RETURN
       END IF
       q(:,:,sw(1)) = q(:,:,sw(1)) + dt * qd
       ws1 = (q(:,:,sw(1)) + q(:,:,sw(2))) / 2.0_prec
    END IF
    IF (PRESENT(encounters)) THEN
       DEALLOCATE(encounters_, stat=err)
       IF (err /= 0) THEN
          error = .TRUE.
          WRITE(0,"(A)") "step_midpoint_full_jpl: Could not deallocate memory (5)."
          RETURN
       END IF
    END IF

  END SUBROUTINE step_midpoint_full_jpl





  !! *Description*:
  !!
  !!   Rational and polynomial function extrapolation for
  !!   (Gragg-)Bulirsch-Stoer integration.
  !!
  !!   These routines are applicable to single vectors or single matrices
  !!   or to groups of vectors or matrices.
  !!   Extrapolation is always towards zero.
  !!   Extrapolation converges when all of the elements of a vector/matrix
  !!   are converged. For groups of N vectors/matrices, convergence is checked
  !!   individually N times.
  !!
  !! References:
  !!   [1] Press et al. 1989, Numerical Recipes.
  !!   [2] Stoer & Bulirsch 1980, Introduction to Num. Anal.
  !!
  !! Usage:
  !!   CALL ratf_extrapolation(z, h, w0, w1, ddif, converged)
  !!   CALL polf_extrapolation(z, h, w0, w1, ddif, converged)
  !!
  !! Fill one diagonal in rational function extrapolation table.
  !! Applicable to vectors.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flag for convergence
  !!
  SUBROUTINE ratf_extrapolation_vec(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                         :: z
    REAL(prec), DIMENSION(:), INTENT(in)        :: h
    REAL(prec), DIMENSION(:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:), INTENT(inout) :: ddif
    LOGICAL, INTENT(out)                        :: converged
    LOGICAL, INTENT(inout)                      :: error

    REAL(prec), DIMENSION(:), ALLOCATABLE :: cdif, tmp1, tmp2
    REAL(prec) :: delta
    INTEGER :: i, j, k, err

    ! Fill in the extrapolation table: (see [1] pp. 80-86 & 563-568)
    ! Here, tables are indexed as (i,j), where the rows i represent
    ! integrations with seq(i) substeps and columns j extrapolations
    ! with j extrapolation points (cf. [1]: j=m+1 in (3.2.8)).
    ! Table ddif is filled like this:
    !   w0(1)   ddif(1,2) ddif(1,3)     ...
    !   w0(2)   ddif(2,2)         0     ...
    !   w0(3)           0         0     ...
    !     ...
    ! Extrapolated value to stepsize=0 is w0(3)+ddif(2,2)+ddif(1,3).

    converged = .FALSE.
    w1(:,z) = w0(:,z)

    IF (z == 1) THEN
       RETURN
    END IF

    ALLOCATE(cdif(SIZE(w0,dim=1)), tmp1(SIZE(w0,dim=1)), &
         tmp2(SIZE(w0,dim=1)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(cdif, tmp1, tmp2, stat=err)
       RETURN
    END IF

    ddif(:,z-1,1) = w0(:,z-1)
    cdif          = w0(:,z)

    DO i=z-1, 1, -1
       j    = z - i + 1
       tmp1 = h(i) / h(z) * ddif(:,i,j-1)
       tmp2 = (tmp1 - cdif)
       DO k=1, 6
          ! Check for division by zero.
          IF (tmp2(k) /= 0) THEN
             tmp2(k)     = (cdif(k) - ddif(k,i,j-1)) / tmp2(k)
             ddif(k,i,j) = cdif(k) * tmp2(k)
             cdif(k)     = tmp1(k) * tmp2(k)
             ! Add difference towards final extrapolation.
             w1(k,z)     = w1(k,z) + ddif(k,i,j)
          ELSE
             ddif(k,i,j) = 0.0_prec
             cdif(k)     = 0.0_prec
          END IF
       END DO
    END DO

    ! Check if extrapolation is converged.
    delta = MAXVAL(ABS(ddif(:,1,z)))
    IF (delta < bs_extrapol_tol) THEN
       converged = .TRUE.
    END IF

    DEALLOCATE(cdif, tmp1, tmp2, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE ratf_extrapolation_vec





  !! Fill one diagonal in polynomial function extrapolation table.
  !! Applicable to vectors.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences
  !!  converged  flag for convergence
  !!
  SUBROUTINE polf_extrapolation_vec(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                         :: z
    REAL(prec), DIMENSION(:), INTENT(in)        :: h
    REAL(prec), DIMENSION(:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:), INTENT(inout) :: ddif
    LOGICAL, INTENT(out)                        :: converged
    LOGICAL, INTENT(inout)                      :: error

    REAL(prec)                            :: delta
    REAL(prec), DIMENSION(:), ALLOCATABLE :: cdif, tmp
    INTEGER                               :: i, j, err

    converged = .FALSE.
    w1(:,z) = w0(:,z)

    IF (z == 1) THEN
       RETURN
    END IF

    ALLOCATE(cdif(SIZE(w0,dim=1)), tmp(SIZE(w0,dim=1)), &
         stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(cdif, tmp, stat=err)
       RETURN
    END IF

    ddif(:,z-1,1) = w0(:,z-1)
    cdif          = w0(:,z)

    DO i=z-1, 1, -1
       j           = z - i + 1
       tmp         = (cdif - ddif(:,i,j-1)) / (h(i) - h(z))
       ddif(:,i,j) = h(z) * tmp
       cdif        = h(i) * tmp
       w1(:,z)     = w1(:,z) + ddif(:,i,j)
    END DO

    ! Check if extrapolation is converged.
    delta = MAXVAL(ABS(ddif(:,1,z)))
    IF (delta < bs_extrapol_tol) THEN
       converged = .TRUE.
    END IF

    DEALLOCATE(cdif, tmp, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE polf_extrapolation_vec





  !! Fill one diagonal in rational function extrapolation table.
  !! Applicable to matrices.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flag for convergence
  !!
  SUBROUTINE ratf_extrapolation_mat(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                           :: z
    REAL(prec), DIMENSION(:), INTENT(in)          :: h
    REAL(prec), DIMENSION(:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, INTENT(out)                          :: converged
    LOGICAL, INTENT(inout)                        :: error

    INTEGER                            :: i, err
    LOGICAL, DIMENSION(:), ALLOCATABLE :: column_ok

    ! This routine calls ratf_extrapolation_vec (for vectors) for each
    ! column of the extrapolated matrix. Therefore, the last index of
    ! w0, w1, and ddif is the column index of the matrix. Note this
    ! when accessing the corresponding actual arguments.

    converged = .FALSE.

    ALLOCATE(column_ok(SIZE(w0,dim=3)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(column_ok, stat=err)
       RETURN
    END IF

    DO i=1, SIZE(w0,dim=3)
       CALL ratf_extrapolation_vec(z, h, w0(:,:,i), w1(:,:,i), &
            ddif(:,:,:,i), column_ok(i), error)
       IF (error) THEN
          DEALLOCATE(column_ok, stat=err)
          RETURN
       END IF
    END DO
    IF (ALL(column_ok)) THEN
       converged = .TRUE.
    END IF

    DEALLOCATE(column_ok, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE ratf_extrapolation_mat





  !! Fill one diagonal in polynomial function extrapolation table.
  !! Applicable to matrices.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences
  !!  converged  flag for convergence
  !!
  SUBROUTINE polf_extrapolation_mat(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                           :: z
    REAL(prec), DIMENSION(:), INTENT(in)          :: h
    REAL(prec), DIMENSION(:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, INTENT(out)                          :: converged
    LOGICAL, INTENT(inout)                        :: error

    INTEGER                            :: i, err
    LOGICAL, DIMENSION(:), ALLOCATABLE :: column_ok

    converged = .FALSE.

    ALLOCATE(column_ok(SIZE(w0,dim=3)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(column_ok, stat=err)
       RETURN
    END IF

    DO i=1, SIZE(w0,dim=3)
       CALL polf_extrapolation_vec(z, h, w0(:,:,i), w1(:,:,i), &
            ddif(:,:,:,i), column_ok(i), error)
       IF (error) THEN
          DEALLOCATE(column_ok, stat=err)
          RETURN
       END IF
    END DO
    IF (ALL(column_ok)) THEN
       converged = .TRUE.
    END IF

    DEALLOCATE(column_ok, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE polf_extrapolation_mat





  !! Fill one diagonal in rational function extrapolation table.
  !! Applicable to N individual vectors.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flags for convergence
  !!
  SUBROUTINE ratf_extrapolation_vec_n(z, h, w0, w1, ddif, converged, error)

    INTEGER, INTENT(in)                           :: z
    REAL(prec), DIMENSION(:), INTENT(in)          :: h
    REAL(prec), DIMENSION(:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, DIMENSION(:), INTENT(inout)          :: converged
    LOGICAL, INTENT(inout)                        :: error

    ! The last index of w0, w1, and ddif is now N, the number of vectors.
    ! "converged"-flags are used to check which vectors need further
    ! extrapolation.

    INTEGER :: i

    DO i=1, SIZE(w0,dim=3)
       IF (converged(i)) CYCLE
       CALL ratf_extrapolation_vec(z, h, w0(:,:,i), w1(:,:,i), &
            ddif(:,:,:,i), converged(i), error)
       IF (error) THEN
          RETURN
       END IF
    END DO

  END SUBROUTINE ratf_extrapolation_vec_n





  !! Fill one diagonal in polynomial function extrapolation table.
  !! Applicable to N individual vectors.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flags for convergence
  !!
  SUBROUTINE polf_extrapolation_vec_n(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                           :: z
    REAL(prec), DIMENSION(:), INTENT(in)          :: h
    REAL(prec), DIMENSION(:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, DIMENSION(:), INTENT(inout)          :: converged
    LOGICAL, INTENT(inout)                        :: error

    INTEGER :: i

    DO i=1, SIZE(w0,dim=3)
       IF (converged(i)) CYCLE
       CALL polf_extrapolation_vec(z, h, w0(:,:,i), w1(:,:,i), &
            ddif(:,:,:,i), converged(i), error)
       IF (error) THEN
          RETURN
       END IF
    END DO

  END SUBROUTINE polf_extrapolation_vec_n





  !! Fill one diagonal in rational function extrapolation table.
  !! Applicable to N individual matrices.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flags for convergence
  !!
  SUBROUTINE ratf_extrapolation_mat_n(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                             :: z
    REAL(prec), DIMENSION(:), INTENT(in)            :: h
    REAL(prec), DIMENSION(:,:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, DIMENSION(:), INTENT(inout)            :: converged
    LOGICAL, INTENT(inout)                          :: error

    ! The last index of w0, w1, and ddif is N, the number of vectors.
    ! The index before the last one is the column index of the matrix.
    ! Only matrices that are not already converged are extrapolated further.

    INTEGER :: i, j, err
    LOGICAL, DIMENSION(:), ALLOCATABLE :: column_ok

    ALLOCATE(column_ok(SIZE(w0,dim=3)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(column_ok, stat=err)
       RETURN
    END IF

    DO i=1, SIZE(w0,dim=4)
       IF (converged(i)) CYCLE
       DO j=1, SIZE(w0,dim=3)
          CALL ratf_extrapolation_vec(z, h, w0(:,:,j,i), w1(:,:,j,i), &
               ddif(:,:,:,j,i), column_ok(j), error)
          IF (error) THEN
             DEALLOCATE(column_ok, stat=err)
             RETURN
          END IF
       END DO
       IF (ALL(column_ok)) THEN
          converged(i) = .TRUE.
       END IF
    END DO

    DEALLOCATE(column_ok, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE ratf_extrapolation_mat_n





  !! Fill one diagonal in polynomial function extrapolation table.
  !! Applicable to N individual matrices.
  !!
  !!  z          index to process in extrapolation table
  !!  h          sequence of step sizes used
  !!  w0         integrations corresponding the step sizes h
  !!  w1         extrapolated values with z integrations
  !!  ddif       extrapolation table with differences (see below)
  !!  converged  flags for convergence
  !!
  SUBROUTINE polf_extrapolation_mat_n(z, h, w0, w1, ddif, converged, &
       error)

    INTEGER, INTENT(in)                             :: z
    REAL(prec), DIMENSION(:), INTENT(in)            :: h
    REAL(prec), DIMENSION(:,:,:,:), INTENT(in)      :: w0
    REAL(prec), DIMENSION(:,:,:,:), INTENT(out)     :: w1
    REAL(prec), DIMENSION(:,:,:,:,:), INTENT(inout) :: ddif
    LOGICAL, DIMENSION(:), INTENT(inout)            :: converged
    LOGICAL, INTENT(inout)                          :: error

    INTEGER :: i, j, err
    LOGICAL, DIMENSION(:), ALLOCATABLE :: column_ok

    ALLOCATE(column_ok(SIZE(w0,dim=3)), stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(column_ok, stat=err)
       RETURN
    END IF

    DO i=1, SIZE(w0,dim=4)
       IF (converged(i)) CYCLE
       DO j=1, SIZE(w0,dim=3)
          CALL polf_extrapolation_vec(z, h, w0(:,:,j,i), w1(:,:,j,i), &
               ddif(:,:,:,j,i), column_ok(j), error)
          IF (error) THEN
             DEALLOCATE(column_ok, stat=err)
             RETURN
          END IF
       END DO
       IF (ALL(column_ok)) THEN
          converged(i) = .TRUE.
       END IF
    END DO

    DEALLOCATE(column_ok, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE polf_extrapolation_mat_n





  !! Gauss-Radau integrator by Edgar Everhart
  !! (Physics Department, University of Denver)
  !!
  !! This 15th-order version is written out for faster execution.
  !! y'=f(y,t) is clss=1, y"=f(y,t) is clss= -2, and y"=f(y',y,t)
  !! is clss=2. mjd_tdt1 is t(final), and mjd_tdt0 is t(initial).
  !! ll controls sequence size. Thus ss=10**(-ll) controls the size
  !! of a term. A typical ll-value is in the range 6 to 12. However,
  !! if ll<0 then step is the constant sequence size used. celements
  !! enter as the starting position-velocity vector, at time
  !! mjd_tdt0, and are output as the final position-velocity vector
  !! at time mjd_tdt1. Integration is in real(8) precision, also
  !! known as 'double precision'.
  !!
  !! References:
  !! E. Everhart (1985), 'An efficient integrator that uses
  !! Gauss-Radau spacings', A. Carusi and G. B. Valsecchi (eds.),
  !! Dynamics of Comets: Their Origin and Evolution (proceedings),
  !! Astrophysics and Space Science Library, vol. 115, D. Reidel
  !! Publishing Company
  !!
  !! E. Everhart (1974), 'Implicit single-sequence methods for
  !! integrating orbits', Celestial Mechanics, vol. 10, no. 1,
  !! pp. 35-55
  !!
  !!
  !! Input/output parameters:
  !! mjd_tdt0         integration start (MJD TT)
  !! mjd_tdt1         integration stop (MJD TT)
  !! celements        initial coordinates for massless particles and additional perturbers (1:6,1:nparticles)
  !! ll
  !! clss
  !! perturbers
  !! error            returns true, if something fails
  !! jacobian         jacobian matrix (new coordinates wrt initial coordinates)
  !! step             step size
  !! ncenter          number of solar-system object to use as center (default=Sun)
  !! encounters       table containing the closest distances to, or earliest
  !!                  time of impact with solar-system objects
  !! masses     masses for additional perturbing bodies
  !!
  !!
  !! @author MG (in f95)
  !! @version   01.03.2010
  !!
  !!
  !! WARNING: jacobians do not yet work properly!
  !!
  SUBROUTINE gauss_radau_15_full_jpl(mjd_tdt0, mjd_tdt1, celements, &
       ll, clss, perturbers, asteroid_perturbers, error, jacobian, step, ncenter, &
       encounters, masses)

    IMPLICIT NONE
    REAL(prec), INTENT(in)                                :: mjd_tdt0, mjd_tdt1
    REAL(prec), DIMENSION(:,:), INTENT(inout)             :: celements
    INTEGER, INTENT(in)                                   :: ll, clss
    LOGICAL, DIMENSION(:), INTENT(in)                     :: perturbers
    LOGICAL, INTENT(in)                                   :: asteroid_perturbers
    LOGICAL, INTENT(inout)                                :: error
    REAL(prec), DIMENSION(:,:,:), INTENT(inout), OPTIONAL :: jacobian
    REAL(prec), INTENT(in), OPTIONAL                      :: step
    INTEGER, INTENT(in), OPTIONAL                         :: ncenter
    REAL(prec), DIMENSION(:,:,:), INTENT(out), OPTIONAL   :: encounters
    REAL(prec), DIMENSION(:), INTENT(in), OPTIONAL        :: masses

    ! Gauss-Radau spacings h, scaled to the range [0,1] for
    ! integrating to the 15th order. The sum of these values
    ! should be 3.73333333...
    REAL(prec), DIMENSION(8), PARAMETER :: h = (/ 0.0_prec, &
         0.05626256053692215_prec, 0.18024069173689236_prec, &
         0.35262471711316964_prec, 0.54715362633055538_prec, &
         0.73421017721541053_prec, 0.88532094683909577_prec, &
         0.97752061356128750_prec /)
    INTEGER, DIMENSION(8), PARAMETER :: nw = (/ 0, 0, 1, 3, 6, 10, 15, 21 /)
    REAL(prec), DIMENSION(:,:,:), ALLOCATABLE ::b, g, e, encounters_, bd, pwd_massless
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: w_massless1, &
         w_massless2, wd_massless1, wd_massless2
    REAL(prec), DIMENSION(21) :: c, d, r
    REAL(prec), DIMENSION(7) :: w, u
    REAL(prec), DIMENSION(3) :: tmp, gk
    REAL(prec) :: direction, dt, pw, t, tp, w1, ss, tm, t2, tval, s, &
         q, hv, xl
    INTEGER :: i, j, jd, k, l, m, n, ww, la, lb, lc, ld, le, ncount, &
         ns, nf, ni, err, naddit, norb, iorb
    LOGICAL :: starting_seq, last_seq

    IF (PRESENT(step)) THEN
       xl = step
    ELSE
       xl = step_def ! default step
    END IF
    norb = SIZE(celements,dim=2)
    IF (norb == 0) THEN
       error = .TRUE.
       WRITE(0,"(A)") "gauss_radau_15_full_jpl: No input orbits available."
       RETURN
    END IF

    ! Reset the global module parameter
    IF (PRESENT(ncenter)) THEN
       central_body = ncenter
    ELSE
       central_body = central_body_prm
    END IF

    IF (PRESENT(masses)) THEN
       naddit = SIZE(masses)
    ELSE
       naddit = 0
    END IF

    IF (PRESENT(jacobian)) THEN
       error = .TRUE.
       WRITE(0,"(A)") "gauss_radau_15_full_jpl: computation of jacobians not yet available."
       RETURN
       ALLOCATE(w_massless1(6,norb*7), w_massless2(6,norb*7), &
            wd_massless1(6,norb*7), wd_massless2(6,norb*7), &
            pwd_massless(6,6,norb), b(7*norb,7,3), g(7*norb,7,3), &
            e(7*norb,7,3), bd(7*norb,7,3), stat=err)
       w_massless1(1:6,1:norb) = celements(1:6,1:norb)
       DO i=1,norb
          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1,1:6,i)
          w_massless1(1:6,norb+(i-1)*6+2) = jacobian(2,1:6,i)
          w_massless1(1:6,norb+(i-1)*6+3) = jacobian(3,1:6,i)
          w_massless1(1:6,norb+(i-1)*6+4) = jacobian(4,1:6,i)
          w_massless1(1:6,norb+(i-1)*6+5) = jacobian(5,1:6,i)
          w_massless1(1:6,norb+(i-1)*6+6) = jacobian(6,1:6,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,1,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,2,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,3,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,4,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,5,i)
!!$          w_massless1(1:6,norb+(i-1)*6+1) = jacobian(1:6,6,i)
       END DO
       w_massless2 = 0.0_prec
    ELSE
       ALLOCATE(w_massless1(6,norb), w_massless2(6,norb), &
            wd_massless1(6,norb), wd_massless2(6,norb), &
            b(norb,7,3), g(norb,7,3), e(norb,7,3), &
            bd(norb,7,3), stat=err)
       w_massless1(1:6,1:norb) = celements(1:6,1:norb)
       w_massless2 = 0.0_prec
    END IF

    ! Initialize the encounter table
    IF (PRESENT(encounters)) THEN
       IF (SIZE(encounters,dim=1) < norb) THEN
          error = .TRUE.
          WRITE(0,"(A)") "gauss_radau_15_full_jpl: 'encounters' array too small (1)."
          RETURN
       END IF
       IF (SIZE(encounters,dim=2) < 11) THEN
          error = .TRUE.
          WRITE(0,"(A)") "gauss_radau_15_full_jpl: 'encounters' array too small (2)."
          RETURN
       END IF
       IF (SIZE(encounters,dim=3) < 4) THEN
          error = .TRUE.
          WRITE(0,"(A)") "gauss_radau_15_full_jpl: 'encounters' array too small (3)."
          RETURN
       END IF
       encounters = HUGE(encounters)
       encounters(:,:,2) = 3
       ALLOCATE(encounters_(SIZE(encounters,dim=1),SIZE(encounters,dim=2),SIZE(encounters,dim=3)))
    END IF

    starting_seq = .TRUE.
    last_seq = .FALSE.
    dt = mjd_tdt1 - mjd_tdt0
    IF (dt > 0.0_prec) THEN
       direction = 1.0_prec
    ELSE
       direction = -1.0_prec
    END IF
    xl = direction*ABS(xl)
    pw = 1.0_prec/9.0_prec
    ! Evaluate the constants in the w-, u-, c-, d-, and r-vectors
    DO n=2,8
       ww = n + n**2
       IF (clss == 1) THEN
          ww = n
       END IF
       w(n-1) = 1.0_prec/ww
       ww = n
       u(n-1) = 1.0_prec/ww
    END DO
    IF (clss == 1) THEN
       w_massless1(4:6,:) = 0.0_prec
    END IF
    bd = 0.0_prec ; b = 0.0_prec ; w1 = 0.5_prec
    IF (clss == 1) THEN
       w1 = 1.0_prec
    END IF
    c(1) = -h(2)
    d(1) = h(2)
    r(1) = 1.0_prec/(h(3)-h(2))
    la = 1 ; lc = 1
    DO k=3,7
       lb = la
       la = lc + 1
       lc = nw(k+1)
       c(la) = -h(k)*c(lb)
       c(lc) = c(la-1) - h(k)
       d(la) = h(2)*d(lb)
       d(lc) = -c(lc)
       r(la) = 1.0_prec/(h(k+1)-h(2))
       r(lc) = 1.0_prec/(h(k+1)-h(k))
       DO l=4,k
          ld = la + l - 3
          le = lb + l - 4
          c(ld) = c(le) - h(k)*c(le+1)
          d(ld) = d(le) + h(l-1)*d(le+1)
          r(ld) = 1.0_prec/(h(k+1)-h(l-1))
       END DO
    END DO
    ! For some reason, the value 10 was declared 10. instead of 10.d0 in
    ! the original version by Everhart (1985). This lead to a difference
    ! in the 12-13 decimal. Here it is declared similar to 10.d0:
    ss = 10.0_prec**(-ll)
    ! The statements above are used only once in an integration to set up the
    ! constants. They use less than a second of execution time. Next set in
    ! a reasonable estimate to tp based on experience. Same sign as direction.
    ! An initial first sequence size can be set with xl even with ll positive.
    tp = 0.1_prec*direction
    IF (ABS(xl) > TINY(xl) .OR. ll < 0.0_prec) THEN
       tp = xl
    END IF
    IF (tp/dt > 0.5_prec) THEN
       tp = 0.5_prec*dt
    END IF
    ncount = 0
    ! The starting place of the first sequence.
    one:DO
       ns = 0 ; nf = 0 ; ni = 6 ; tm = 0.0_prec
       IF (PRESENT(jacobian)) THEN
          IF (PRESENT(encounters)) THEN
             CALL interact_full_jpl(w_massless1(1:6,1:norb), mjd_tdt0+tm, &
                  perturbers, asteroid_perturbers, wd_massless1, error, pwd_massless, &
                  encounters=encounters_, masses=masses)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL interact_full_jpl(w_massless1(1:6,1:norb), mjd_tdt0+tm, &
                  perturbers, asteroid_perturbers, wd_massless1, error, pwd_massless, masses=masses)
!!$          CALL interact_full_jpl_center(w_massless1(1:6,1:norb), mjd_tdt0+tm, &
!!$               wd_massless1, error, pwd_massless)
          END IF
          DO i=1,norb
             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1,1:6,i)
             w_massless1(1:6,norb+(i-1)*6+2) = pwd_massless(2,1:6,i)
             w_massless1(1:6,norb+(i-1)*6+3) = pwd_massless(3,1:6,i)
             w_massless1(1:6,norb+(i-1)*6+4) = pwd_massless(4,1:6,i)
             w_massless1(1:6,norb+(i-1)*6+5) = pwd_massless(5,1:6,i)
             w_massless1(1:6,norb+(i-1)*6+6) = pwd_massless(6,1:6,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,1,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,2,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,3,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,4,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,5,i)
!!$             w_massless1(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,6,i)
          END DO
       ELSE
          IF (PRESENT(encounters)) THEN
             CALL interact_full_jpl(w_massless1, mjd_tdt0+tm, &
                  perturbers, asteroid_perturbers, wd_massless1, error, encounters=encounters_, &
                  masses=masses)
             ! Log closest non-impacting encounter during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
             ! Log earliest time of impact during the integration step
             FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                  NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                  encounters_(m,n,1) < encounters(m,n,1))
                encounters(m,n,:) = encounters_(m,n,:)
             END FORALL
          ELSE
             CALL interact_full_jpl(w_massless1, mjd_tdt0+tm, &
                  perturbers, asteroid_perturbers,wd_massless1, error, masses=masses)
!!$          CALL interact_full_jpl_center(w_massless1, mjd_tdt0+tm, &
!!$               wd_massless1, error)
          END IF
       END IF
       IF (error) THEN
          DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
               wd_massless2, pwd_massless, b, g, e, bd, encounters_, &
               stat=err)
          WRITE(0,"(A)") "gauss_radau_15_full_jpl: TRACE BACK (10)."
          RETURN
       END IF
       nf = nf + 1
       ! Second loop. First find new beta-
       ! values from the predicted b-values, following eq. (2.7) in text.
       DO
          DO iorb=1,SIZE(w_massless1,dim=2)
             g(iorb,1,:) = b(iorb,1,:) + d(1)*b(iorb,2,:) + d(2)*b(iorb,3,:) + d(4)*b(iorb,4,:) + &
                  d( 7)*b(iorb,5,:) + d(11)*b(iorb,6,:) + d(16)*b(iorb,7,:)
             g(iorb,2,:) = b(iorb,2,:) + d(3)*b(iorb,3,:) + d(5)*b(iorb,4,:) + d(8)*b(iorb,5,:) + &
                  d(12)*b(iorb,6,:) + d(17)*b(iorb,7,:)
             g(iorb,3,:) = b(iorb,3,:) + d(6)*b(iorb,4,:) + d(9)*b(iorb,5,:) + d(13)*b(iorb,6,:) + &
                  d(18)*b(iorb,7,:)
             g(iorb,4,:) = b(iorb,4,:) + d(10)*b(iorb,5,:) + d(14)*b(iorb,6,:) + d(19)*b(iorb,7,:)
             g(iorb,5,:) = b(iorb,5,:) + d(15)*b(iorb,6,:) + d(20)*b(iorb,7,:)
             g(iorb,6,:) = b(iorb,6,:) + d(21)*b(iorb,7,:)
             g(iorb,7,:) = b(iorb,7,:)
          END DO
          t = tp
          t2 = t**2.0_prec
          IF (clss == 1) THEN
             t2 = t
          END IF
          tval = ABS(t)
          ! This loop is 6 iterations on first sequence and two iterations therafter.
          DO m=1,ni
             ! This loop is for each substep within a sequence.
             DO j=2,8
                jd = j - 1
                s = h(j)
                q = s
                IF (clss == 1) THEN
                   q = 1.0_prec
                END IF
                DO iorb=1,SIZE(w_massless2,dim=2)
                   ! Use eqs. (2.9) and (2.10) of text to predict
                   ! positions at each substep:
                   w_massless2(1:3,iorb) = w_massless1(1:3,iorb) + &
                        q*(t*w_massless1(4:6,iorb) + &
                        t2*s*(wd_massless1(4:6,iorb)*w1 + &
                        s*(w(1)*b(iorb,1,:) + s*(w(2)*b(iorb,2,:) + &
                        s*(w(3)*b(iorb,3,:) + s*(w(4)*b(iorb,4,:) + &
                        s*(w(5)*b(iorb,5,:) + s*(w(6)*b(iorb,6,:) + &
                        s*w(7)*b(iorb,7,:)))))))))
                   IF (clss == 2) THEN
                      ! Calculate the velocity predictors needed
                      ! for general clss ii.
                      w_massless2(4:6,iorb) = w_massless1(4:6,iorb) + &
                           s*t*(wd_massless1(4:6,iorb) + &
                           s*(u(1)*b(iorb,1,:) + &
                           s*(u(2)*b(iorb,2,:) + s*(u(3)*b(iorb,3,:) + &
                           s*(u(4)*b(iorb,4,:) + s*(u(5)*b(iorb,5,:) + &
                           s*(u(6)*b(iorb,6,:) + s*u(7)*b(iorb,7,:))))))))
                   END IF
                END DO
                ! Find forces at each substep.
                IF (PRESENT(jacobian)) THEN
                   IF (PRESENT(encounters)) THEN
                      CALL interact_full_jpl(w_massless2(:,1:norb), mjd_tdt0+tm+s*t, &
                           perturbers, asteroid_perturbers, wd_massless2, error, pwd_massless, &
                           encounters=encounters_, masses=masses)
                      ! Log closest non-impacting encounter during the integration step
                      FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                           NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                         encounters(m,n,:) = encounters_(m,n,:)
                      END FORALL
                      ! Log earliest time of impact during the integration step
                      FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                           NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                           encounters_(m,n,1) < encounters(m,n,1))
                         encounters(m,n,:) = encounters_(m,n,:)
                      END FORALL
                   ELSE
                      CALL interact_full_jpl(w_massless2(:,1:norb), mjd_tdt0+tm+s*t, &
                           perturbers, asteroid_perturbers, wd_massless2, error, pwd_massless, &
                           masses=masses)
!!$                   CALL interact_full_jpl_center(w_massless2(:,1:norb), mjd_tdt0+tm+s*t, &
!!$                        wd_massless2, error, pwd_massless)
                   END IF
                   DO i=1,norb
                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1,1:6,i)
                      w_massless2(1:6,norb+(i-1)*6+2) = pwd_massless(2,1:6,i)
                      w_massless2(1:6,norb+(i-1)*6+3) = pwd_massless(3,1:6,i)
                      w_massless2(1:6,norb+(i-1)*6+4) = pwd_massless(4,1:6,i)
                      w_massless2(1:6,norb+(i-1)*6+5) = pwd_massless(5,1:6,i)
                      w_massless2(1:6,norb+(i-1)*6+6) = pwd_massless(6,1:6,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,1,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,2,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,3,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,4,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,5,i)
!!$                      w_massless2(1:6,norb+(i-1)*6+1) = pwd_massless(1:6,6,i)
                   END DO
                ELSE
                   IF (PRESENT(encounters)) THEN
                      CALL interact_full_jpl(w_massless2, &
                           mjd_tdt0+tm+s*t, perturbers, asteroid_perturbers, &
                           wd_massless2, &
                           error, encounters=encounters_, masses=masses)
                      ! Log closest non-impacting encounter during the integration step
                      FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                           NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                         encounters(m,n,:) = encounters_(m,n,:)
                      END FORALL
                      ! Log earliest time of impact during the integration step
                      FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                           NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                           encounters_(m,n,1) < encounters(m,n,1))
                         encounters(m,n,:) = encounters_(m,n,:)
                      END FORALL
                   ELSE
                      CALL interact_full_jpl(w_massless2, &
                           mjd_tdt0+tm+s*t, perturbers, asteroid_perturbers,&
                           wd_massless2, &
                           error, masses=masses)
!!$                   CALL interact_full_jpl_center(w_massless2, mjd_tdt0+tm+s*t, wd_massless2, error)
                   END IF
                END IF
                IF (error) THEN
                   DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
                        wd_massless2, pwd_massless, b, g, e, bd, encounters_, stat=err)
                   WRITE(0,"(A)") "gauss_radau_15_full_jpl: TRACE BACK (20)."
                   RETURN
                END IF
                nf = nf + 1
                DO iorb=1,SIZE(w_massless1,dim=2)
                   ! Find g-value for the force wd_massless2 found at the current substep. This
                   ! section, including the case statement, uses eq. (2.4) of text.
                   tmp = g(iorb,jd,:)
                   gk = (wd_massless2(4:6,iorb)-wd_massless1(4:6,iorb))/s
                   SELECT CASE (j)
                   CASE (2)
                      g(iorb,1,:) = gk
                   CASE (3)
                      g(iorb,2,:) = (gk-g(iorb,1,:))*r(1)
                   CASE (4)
                      g(iorb,3,:) = ((gk-g(iorb,1,:))*r(2) - g(iorb,2,:))*r(3)
                   CASE (5)
                      g(iorb,4,:) = (((gk-g(iorb,1,:))*r(4) - g(iorb,2,:))*r(5) - g(iorb,3,:))*r(6)
                   CASE (6)
                      g(iorb,5,:) = ((((gk-g(iorb,1,:))*r(7) - g(iorb,2,:))*r(8) - g(iorb,3,:))*r(9) - &
                           g(iorb,4,:))*r(10)
                   CASE (7)
                      g(iorb,6,:) = (((((gk-g(iorb,1,:))*r(11) - g(iorb,2,:))*r(12) - &
                           g(iorb,3,:))*r(13) - g(iorb,4,:))*r(14)-g(iorb,5,:))*r(15)
                   CASE (8)
                      g(iorb,7,:) = ((((((gk-g(iorb,1,:))*r(16) - g(iorb,2,:))*r(17) - g(iorb,3,:))*r(18) - &
                           g(iorb,4,:))*r(19) - g(iorb,5,:))*r(20) - g(iorb,6,:))*r(21)
                   END SELECT
                   ! Update all b-values.
                   tmp = g(iorb,jd,:) - tmp
                   b(iorb,jd,:) = b(iorb,jd,:) + tmp
                   ! tmp is now the improvement on g(iorb,jd,:) over its former value.
                   ! Now we upgrade the b-value using this difference in the one term.
                   ! This section is based on eq. (2.5).
                   SELECT CASE (j)
                   CASE (3)
                      b(iorb,1,:) = b(iorb,1,:) + c(1)*tmp
                   CASE (4)
                      b(iorb,1,:) = b(iorb,1,:) + c(2)*tmp
                      b(iorb,2,:) = b(iorb,2,:) + c(3)*tmp
                   CASE (5)
                      b(iorb,1,:) = b(iorb,1,:) + c(4)*tmp
                      b(iorb,2,:) = b(iorb,2,:) + c(5)*tmp
                      b(iorb,3,:) = b(iorb,3,:) + c(6)*tmp
                   CASE (6)
                      b(iorb,1,:) = b(iorb,1,:) + c(7)*tmp
                      b(iorb,2,:) = b(iorb,2,:) + c(8)*tmp
                      b(iorb,3,:) = b(iorb,3,:) + c(9)*tmp
                      b(iorb,4,:) = b(iorb,4,:) + c(10)*tmp
                   CASE (7)
                      b(iorb,1,:) = b(iorb,1,:) + c(11)*tmp
                      b(iorb,2,:) = b(iorb,2,:) + c(12)*tmp
                      b(iorb,3,:) = b(iorb,3,:) + c(13)*tmp
                      b(iorb,4,:) = b(iorb,4,:) + c(14)*tmp
                      b(iorb,5,:) = b(iorb,5,:) + c(15)*tmp
                   CASE (8)
                      b(iorb,1,:) = b(iorb,1,:) + c(16)*tmp
                      b(iorb,2,:) = b(iorb,2,:) + c(17)*tmp
                      b(iorb,3,:) = b(iorb,3,:) + c(18)*tmp
                      b(iorb,4,:) = b(iorb,4,:) + c(19)*tmp
                      b(iorb,5,:) = b(iorb,5,:) + c(20)*tmp
                      b(iorb,6,:) = b(iorb,6,:) + c(21)*tmp
                   END SELECT
                END DO
             END DO
             IF (ll >= 0.0_prec .AND. m >= ni) THEN
                ! Integration of sequence is over. Next is sequence size control.
                hv = MAXVAL(ABS(b(1,7,:)))
                DO iorb=2,SIZE(b,dim=1)
                   IF (hv < MAXVAL(ABS(b(iorb,7,:)))) THEN
                      hv = MAXVAL(ABS(b(iorb,7,:)))
                   END IF
                END DO
                hv = hv*w(7)/tval**7.0_prec
             END IF
          END DO
          !return
          IF (starting_seq) THEN
             IF (ll >= 0.0_prec) THEN
                tp = (ss/hv)**pw*direction
                IF (tp/t <= 1.0_prec) THEN
                   tp = 0.8_prec*tp
                   ncount = ncount + 1
                   IF (ncount > 10) THEN
                      error = .TRUE.
                      DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
                           wd_massless2, pwd_massless, b, g, e, bd, &
                           encounters_, stat=err)
                      WRITE(0,"(A)") "gauss_radau_15_full_jpl: ncount > 10."
                      RETURN
                   END IF
                   ! restart with 0.8x sequence size if new size called for is smaller than
                   ! originally chosen starting sequence size on first sequence.
                   CYCLE one
                END IF
             ELSE
                tp = xl
             END IF
             starting_seq = .FALSE.
             ! Loop 35 finds new x and v values at end of sequence using eqs. (2.11),(2.12)
          END IF
          DO iorb=1,SIZE(w_massless1,dim=2)
             w_massless1(1:3,iorb) = w_massless1(1:3,iorb) + w_massless1(4:6,iorb)*t + &
                  t2*(wd_massless1(4:6,iorb)*w1 + b(iorb,1,:)*w(1) + &
                  b(iorb,2,:)*w(2) + b(iorb,3,:)*w(3) + b(iorb,4,:)*w(4) + &
                  b(iorb,5,:)*w(5) + b(iorb,6,:)*w(6)+b(iorb,7,:)*w(7))
             IF (clss /= 1) THEN
                w_massless1(4:6,iorb) = w_massless1(4:6,iorb) + t*(wd_massless1(4:6,iorb) &
                     + b(iorb,1,:)*u(1) + b(iorb,2,:)*u(2) + b(iorb,3,:)*u(3) + &
                     b(iorb,4,:)*u(4) + b(iorb,5,:)*u(5) + b(iorb,6,:)*u(6) + &
                     b(iorb,7,:)*u(7))
             END IF
          END DO
          tm = tm + t
          ns = ns + 1
          ! Return if done.
          IF (last_seq) THEN
             IF (PRESENT(jacobian)) THEN
                celements(1:6,1:norb) = w_massless1(1:6,1:norb)
                DEALLOCATE(pwd_massless, stat=err)
                IF (err /= 0) THEN
                   error = .TRUE.
                   DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
                        wd_massless2, b, g, e, bd, encounters_, stat=err)
                   WRITE(0,"(A)") "gauss_radau_15_full_jpl: Memory deallocation failed (10)."
                   RETURN
                END IF
             ELSE
                celements = w_massless1
             END IF
             IF (PRESENT(encounters)) THEN
                DEALLOCATE(encounters_, stat=err)
                IF (err /= 0) THEN
                   error = .TRUE.
                   WRITE(0,"(A)") "gauss_radau_15_full_jpl: Memory deallocation failed (20)."
                   RETURN
                END IF
             END IF
             DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
                  wd_massless2, b, g, e, bd, stat=err)
             IF (err /= 0) THEN
                error = .TRUE.
                WRITE(0,"(A)") "gauss_radau_15_full_jpl: Memory deallocation failed (30)."
                RETURN
             END IF
             RETURN
          END IF
          ! Control on size of next sequence and adjust last sequence to exactly
          ! cover the integration span. last_seq=.true. Set on last sequence.
          IF (PRESENT(jacobian)) THEN
             IF (PRESENT(encounters)) THEN
                CALL interact_full_jpl(w_massless1(1:6,1:norb), mjd_tdt0+tm, &
                     perturbers, asteroid_perturbers, wd_massless1, error, pwd_massless, &
                     encounters=encounters_, masses=masses)
                ! Log closest non-impacting encounter during the integration step
                FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                     NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                   encounters(m,n,:) = encounters_(m,n,:)
                END FORALL
                ! Log earliest time of impact during the integration step
                FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                     NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                     encounters_(m,n,1) < encounters(m,n,1))
                   encounters(m,n,:) = encounters_(m,n,:)
                END FORALL
             ELSE
                CALL interact_full_jpl(w_massless1(1:6,1:norb), mjd_tdt0+tm, &
                     perturbers, asteroid_perturbers, wd_massless1, error, pwd_massless, &
                     masses=masses)
             END IF
          ELSE
             IF (PRESENT(encounters)) THEN
                CALL interact_full_jpl(w_massless1, mjd_tdt0+tm, &
                     perturbers, asteroid_perturbers, wd_massless1, error, &
                     encounters=encounters_, masses=masses)
                ! Log closest non-impacting encounter during the integration step
                FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                     NINT(encounters(m,n,2)) >= 2 .AND. encounters_(m,n,3) < encounters(m,n,3))
                   encounters(m,n,:) = encounters_(m,n,:)
                END FORALL
                ! Log earliest time of impact during the integration step
                FORALL (m=1:SIZE(encounters,dim=1), n=1:SIZE(encounters,dim=2), &
                     NINT(encounters(m,n,2)) == 1 .AND. NINT(encounters_(m,n,2)) == 1 .AND. &
                     encounters_(m,n,1) < encounters(m,n,1))
                   encounters(m,n,:) = encounters_(m,n,:)
                END FORALL
             ELSE
                CALL interact_full_jpl(w_massless1, mjd_tdt0+tm, &
                     perturbers, asteroid_perturbers, wd_massless1, error, &
                     masses=masses)
             END IF
          END IF
          IF (error) THEN
             DEALLOCATE(w_massless1, w_massless2, wd_massless1, &
                  wd_massless2, pwd_massless, b, g, e, bd, &
                  encounters_, stat=err)
             WRITE(0,"(A)") "gauss_radau_15_full_jpl: TRACE BACK (30)."
             RETURN
          END IF
          nf = nf + 1
          IF (ll >= 0.0_prec) THEN
             tp = direction*(ss/hv)**pw
             IF (tp/t > 1.4_prec) THEN
                tp = t*1.4_prec
             END IF
          END IF
          IF (ll < 0.0_prec) THEN
             tp = xl
          END IF
          IF (direction*(tm+tp) >= direction*dt - 1.e-8_prec) THEN
             tp = dt - tm
             last_seq = .TRUE.
          END IF
          ! Now predict b-values for next step. The predicted values from the preceding
          ! sequence were saved in the e-matrix. The correction bd between the actual
          ! b-values found and these predicted values is applied in advance to the
          ! next sequence. The gain in accuracy is significant. Using eqs. (2.13):
          q = tp/t
          DO iorb=1,SIZE(w_massless1,dim=2)
             IF (ns /= 1) THEN
                bd(iorb,1:7,:) = b(iorb,1:7,:) - e(iorb,1:7,:)
             END IF
             e(iorb,1,:) = q*(b(iorb,1,:) + 2.0_prec*b(iorb,2,:) + &
                  3.0_prec*b(iorb,3,:) + 4._prec*b(iorb,4,:) + 5._prec*b(iorb,5,:) + &
                  6._prec*b(iorb,6,:) + 7._prec*b(iorb,7,:))
             e(iorb,2,:) = q**2*(b(iorb,2,:) + 3.0_prec*b(iorb,3,:) + 6.0_prec*b(iorb,4,:) + &
                  10.0_prec*b(iorb,5,:) + 15.0_prec*b(iorb,6,:)+ 21.0_prec*b(iorb,7,:))
             e(iorb,3,:) = q**3*(b(iorb,3,:) + 4.0_prec*b(iorb,4,:) + 10.0_prec*b(iorb,5,:)+ &
                  20.0_prec*b(iorb,6,:)+ 35.0_prec*b(iorb,7,:))
             e(iorb,4,:) = q**4*(b(iorb,4,:) + 5.0_prec*b(iorb,5,:) + 15.0_prec*b(iorb,6,:) + &
                  35.0_prec*b(iorb,7,:))
             e(iorb,5,:) = q**5*(b(iorb,5,:) + 6.0_prec*b(iorb,6,:) + 21.0_prec*b(iorb,7,:))
             e(iorb,6,:) = q**6*(b(iorb,6,:) + 7.0_prec*b(iorb,7,:))
             e(iorb,7,:) = q**7*b(iorb,7,:)
             b(iorb,1:7,:) = e(iorb,1:7,:) + bd(iorb,1:7,:)
          END DO
          ! Two iterations for every sequence after the first.
          ni = 2
       END DO
       EXIT
    END DO one

  END SUBROUTINE gauss_radau_15_full_jpl





  !! Description:
  !!
  !! Evaluation of the full Newtonian force function for several
  !! massless bodies. Positions of the massive bodies are read from
  !! JPL ephemerides. A relativistic term due to the Sun is included.
  !! Optional argument triggers evaluation of the partial derivatives
  !! of the force function wrt Cartesian coordinates.
  !!
  !! References:
  !!   [1] Karttunen, Taivaanmekaniikka
  !!
  !! Usage:
  !!   CALL interact_full_jpl(ws, mjd_tdt, wds, error, pwds)
  !!
  !! Interaction.
  !!
  !!  ws           heliocentric, equatorial, Cartesian coordinates for bodies
  !!                that need to be integrated (massless particles +
  !!                additional perturbers)
  !!  mjd_tdt      modified Julian date (for ephemerides)
  !!  wds          evaluated force function
  !!  perturbers   boolean mask for the basic set of perturbers available (true = use in force model)
  !!  error        true, if reading from ephemerides fails
  !!  pwds         evaluated partial derivatives of the force function
  !!  encounters   encounters(i,j) where i=massless particle,
  !!                j=perturber, encounters(i,j)=1 or 2, where 1=within
  !!                planetary radius (~collision) and 2=outside
  !!                planetary radius
  !!  masses       masses for additional perturbers
  !!  radial_acceleration scalar of force to be added in the direction
  !!               radially outwards from the origin (usually the Sun)
  !!               this is aimed for accounting for radiation pressure
  !!
  SUBROUTINE interact_full_jpl(ws, mjd_tdt, perturbers, asteroid_perturbers, wds, error, &
       pwds, encounters, masses, radial_acceleration)

    REAL(prec), DIMENSION(:,:), INTENT(in)              :: ws
    REAL(prec), INTENT(in)                              :: mjd_tdt
    LOGICAL, DIMENSION(:), INTENT(in)                   :: perturbers ! = basic perturbers (planets + Moon + Pluto)
    LOGICAL, INTENT(in)                                 :: asteroid_perturbers ! BC430 asteroid perturbations.
    REAL(prec), DIMENSION(:,:), INTENT(out)             :: wds
    LOGICAL, INTENT(inout)                              :: error
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(out) :: pwds
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(out) :: encounters
    REAL(prec), DIMENSION(:), OPTIONAL, INTENT(in)      :: masses
    REAL(prec), OPTIONAL, INTENT(in)                    :: radial_acceleration

    ! Number of basic perturbers.
    INTEGER :: N

    ! Number of active basic perturbers.
    INTEGER :: NP

    ! Number of massless bodies.
    INTEGER :: NS

    ! Coordinates for the massive planets.
    REAL(prec), DIMENSION(:,:), POINTER :: wc1 => NULL()
    ! All used bodies.
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: wc

    ! And for the massive asteroids.
    REAL(prec), DIMENSION(:,:), POINTER :: wc2 => NULL()
    REAL(prec), DIMENSION(:), POINTER :: asteroid_masses => NULL()
    ! Various distances.
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: drs
    REAL(prec), DIMENSION(:), ALLOCATABLE :: ir3c
    REAL(prec), DIMENSION(:), ALLOCATABLE :: r2d, ir3d, ir5d
    REAL(prec), DIMENSION(3,SIZE(ws,dim=2)) :: drs_
    REAL(prec), DIMENSION(SIZE(ws,dim=2)) :: ir3c_
    REAL(prec), DIMENSION(SIZE(ws,dim=2)) :: r2d_, ir3d_, ir5d_
    REAL(prec) :: r2c, r2s, ir3s, ir5s, ir4s, v2s, us, ir6s, dist

    ! Utility variables.
    REAL(prec), DIMENSION(3,3) :: A, B, P1, P2
    INTEGER :: i, iaddit, j, k, l, err, naddit

    naddit = 0
    err = 0

    ! Number of basic perturbers, that is, perturbers whose orbits are
    ! not integrated.
    !
    ! Maximum number of planetary perturbers:
    N = SIZE(perturbers)
    ! Number of planetary perturbers considered here:
    NP = COUNT(perturbers) 
    IF (asteroid_perturbers) THEN
       ! Number of asteroidal perturbers considered here:
       wc2 => BC_ephemeris(mjd_tdt, nastpert, error)
       asteroid_masses => BC_masses(nastpert)
    ELSE
       nastpert = 0
    END IF

    ! Allocate memory for basic perturbers
    ALLOCATE(drs(3,N+nastpert))
    ALLOCATE(ir3c(N+nastpert))
    ALLOCATE(r2d(N+nastpert))
    ALLOCATE(ir3d(N+nastpert))
    ALLOCATE(ir5d(N+nastpert))

    ! Number of additional perturbers that will be integrated
    ! simultaneously with the massless test particles.
    IF (PRESENT(masses)) THEN
       DO i=1,SIZE(masses)
          IF (masses(i) > 0.0_prec) THEN
             naddit = naddit + 1
          END IF
       END DO
    END IF

    ! Number of test particles (ie, bodies massless wrt basic perturbers).
    NS = SIZE(ws,dim=2)

    IF (NP > 0) THEN
       ! Get positions of massive bodies (-10 = 9 planets + Moon).
       wc1 => JPL_ephemeris(mjd_tdt, -10, 11, error)
       IF (error) THEN
          DEALLOCATE(wc, stat=err)
          RETURN
       END IF
       IF (nastpert > 0) THEN ! Add asteroid perturbers.
          ALLOCATE(wc(SIZE(wc1,dim=1)+SIZE(wc2,dim=1),6))
          wc(1:SIZE(wc1,dim=1),1:6) = wc1
          wc(SIZE(wc1,dim=1)+1:SIZE(wc2,dim=1)+SIZE(wc1,dim=1),1:6) = wc2
          ! wc has planet perturbers followed by asteroid perturbers.
          DEALLOCATE(wc1)
          DEALLOCATE(wc2)
       ELSE
          ALLOCATE(wc(SIZE(wc1,dim=1),6))
          wc = wc1
          DEALLOCATE(wc1)          
       END IF
    ELSE IF (NP == 0 .AND. nastpert > 0) THEN
       ! Only asteroid perturbers
       ALLOCATE(wc(SIZE(wc2,dim=1),SIZE(wc2,dim=2)))
       wc = wc2
       DEALLOCATE(wc2)
    END IF

    ! Useful quantities.
    ir3c = 0.0_prec
    ir3c_ = 0.0_prec

    ! Basic perturbers
    IF (NP+nastpert > 0) THEN
       DO i=1,N
          IF (perturbers(i)) THEN
             r2c  = DOT_PRODUCT(wc(i,1:3), wc(i,1:3))
             ir3c(i) = 1.0_prec / (r2c * SQRT(r2c))
          END IF
       END DO
       DO i=N+1,N+nastpert
          r2c  = DOT_PRODUCT(wc(i,1:3), wc(i,1:3))
          ir3c(i) = 1.0_prec / (r2c * SQRT(r2c))
       END DO
    END IF

    IF (naddit > 0) THEN
       ! Additional perturbers
       DO i=1,NS
          IF (masses(i) > 0.0_prec) THEN
             r2c  = DOT_PRODUCT(ws(1:3,i), ws(1:3,i))
             ir3c_(i) = 1.0_prec / (r2c * SQRT(r2c))
          END IF
       END DO
    END IF

    ! Loop over bodies to be integrated.
    DO i=1,NS

       r2s  = DOT_PRODUCT(ws(1:3,i), ws(1:3,i)) ! ws(6,NS)
       ir3s = 1.0_prec / (r2s * SQRT(r2s))
       drs = 0.0_prec ; r2d = 0.0_prec ; ir3d = 0.0_prec
       IF (NP > 0) THEN
          ! Log impacts and distances to solar-system objects
          DO j=1,N+nastpert
             ! Basic perturbers. Compute drs and r2d regardless of
             ! perturbers to be included in the force model (as
             ! long as there is at least one perturber included in
             ! the force model) so that the distance to planets can
             ! be logged:
             drs(1:3,j) = wc(j,1:3) - ws(1:3,i)
             r2d(j)     = DOT_PRODUCT(drs(1:3,j), drs(1:3,j))
             ir3d(j)    = 1.0_prec / (r2d(j) * SQRT(r2d(j)))
             IF (PRESENT(encounters)) THEN
                dist = SQRT(r2d(j))
                ! Basic perturbers
                IF (j <= N) THEN
                   IF (dist < planetary_radii(j)) THEN
                      encounters(i,j,1) = mjd_tdt ! date
                      encounters(i,j,2) = 1       ! = impact
                      encounters(i,j,3) = dist    ! distance
                   ELSE
                      encounters(i,j,1) = mjd_tdt ! date
                      encounters(i,j,2) = 2       ! = non-impact
                      encounters(i,j,3) = dist    ! distance
                   END IF
                END IF
             END IF
          END DO
       END IF
       IF (naddit > 0) THEN
          iaddit = 0
          DO j=1,NS
             IF (masses(j) > 0.0_prec) THEN
                iaddit = iaddit + 1
                ! Additional perturbers
                IF (j == i) THEN
                   ! Skip references to self
                   CYCLE
                END IF
                drs_(1:3,j) = ws(1:3,j) - ws(1:3,i)
                r2d_(j)     = DOT_PRODUCT(drs_(1:3,j), drs_(1:3,j))
                ir3d_(j)    = 1.0_prec / (r2d_(j) * SQRT(r2d_(j)))
                IF (PRESENT(encounters)) THEN
                   dist = SQRT(r2d_(j))
                   ! Additional perturbers
                   encounters(i,SIZE(encounters,dim=2)-naddit+iaddit,1) = mjd_tdt ! date
                   encounters(i,SIZE(encounters,dim=2)-naddit+iaddit,2) = 2       ! always non-impact (we don't know the size)
                   encounters(i,SIZE(encounters,dim=2)-naddit+iaddit,3) = dist    ! distance
                END IF
             END IF
             IF (iaddit == naddit) THEN
                EXIT
             END IF
          END DO
       END IF
       IF (PRESENT(encounters)) THEN
          ! Distance to Sun
          dist = SQRT(DOT_PRODUCT(ws(1:3,i), ws(1:3,i)))
          IF (dist < planetary_radii(11)) THEN
             encounters(i,11,1) = mjd_tdt
             encounters(i,11,2) = 1
             encounters(i,11,3) = dist
          ELSE
             encounters(i,11,1) = mjd_tdt
             encounters(i,11,2) = 2
             encounters(i,11,3) = dist
          END IF
       END IF

       ! Initialize force function.
       wds(1:3,i) = ws(4:6,i)
       wds(4:6,i) = 0.0_prec

       ! Non-integrable part of the interaction.
       ! Basic perturbers
       DO j=1,N+nastpert
          IF (j > N) THEN
             wds(4:6,i) = wds(4:6,i) + &
                  asteroid_masses(j-N) * (drs(1:3,j) * ir3d(j) - wc(j,1:3) * ir3c(j))
          ELSE IF (perturbers(j)) THEN
             wds(4:6,i) = wds(4:6,i) + &
                  planetary_masses(j) * (drs(1:3,j) * ir3d(j) - wc(j,1:3) * ir3c(j))
          END IF
       END DO

       IF (naddit > 0) THEN
          ! Additional perturbers
          iaddit = 0
          DO j=1,NS
             IF (masses(j) <= 0.0_prec) THEN
                CYCLE
             END IF
             iaddit = iaddit + 1
             IF (i == j) THEN
                CYCLE
             END IF
             wds(4:6,i) = wds(4:6,i) + &
                  masses(j) * (drs_(1:3,j) * ir3d_(j) - ws(1:3,j) * ir3c_(j))
             IF (iaddit == naddit) THEN
                EXIT
             END IF
          END DO
       END IF
       wds(4:6,i) = gc * wds(4:6,i)

       ! Integrable part of the interaction.
       wds(4:6,i) = wds(4:6,i) - gc * ws(1:3,i) * ir3s

       IF (relativity) THEN
          ! Relativistic term from the Sun (isotropic coordinates).
          ! (Sitarski (1983) AcA 33)
          ir4s = 1.0_prec / (r2s ** 2)
          v2s  = DOT_PRODUCT(ws(4:6,i), ws(4:6,i))
          us   = DOT_PRODUCT(ws(1:3,i), ws(4:6,i))
          wds(4:6,i) = wds(4:6,i) &
               + gc * ((4.0_prec * gc * ir4s - v2s * ir3s) * ws(1:3,i) &
               + 4.0_prec * us * ir3s * ws(4:6,i)) * ic2
       END IF

       IF (PRESENT(radial_acceleration)) THEN
          ! Add radial acceleration caused by, e.g., solar radiation
          ! pressure to massless particles (solar radiation pressure
          ! on massive particles is assumed negligible)
          IF (naddit > 0) THEN
             IF (masses(i) <= 0.0_prec) THEN
                wds(4:6,i) = wds(4:6,i) + &
                     ws(1:3,i) * r2s * ir3s * radial_acceleration
             END IF
          ELSE
             wds(4:6,i) = wds(4:6,i) + &
                  ws(1:3,i) * r2s * ir3s * radial_acceleration
          END IF
       END IF

       ! Optional part.
       IF (PRESENT(pwds)) THEN
          ! Some useful quantities.
          ir5s = ir3s / r2s
          ir5d = ir3d / r2d

          ! Non-integrable part of the interaction
          A = 0.0_prec
          ! Basic perturbers
          DO j=1,N+nastpert
             IF (j > N) THEN
                DO k=1,3
                   DO l=1,3
                      A(k,l) = A(k,l) + 3.0_prec * asteroid_masses(j-N) &
                           * drs(k,j) * drs(l,j) * ir5d(j)
                   END DO
                   A(k,k) = A(k,k) - asteroid_masses(j-N) * ir3d(j)
                END DO
             ELSE IF (perturbers(j)) THEN
                DO k=1,3
                   DO l=1,3
                      A(k,l) = A(k,l) + 3.0_prec * planetary_masses(j) &
                           * drs(k,j) * drs(l,j) * ir5d(j)
                   END DO
                   A(k,k) = A(k,k) - planetary_masses(j) * ir3d(j)
                END DO
             END IF
          END DO
          IF (naddit > 0) THEN
             ! Additional perturbers
             ir5d_ = ir3d_ / r2d_
             iaddit = 0
             DO j=1,NS
                IF (masses(j) <= 0.0_prec) THEN
                   CYCLE
                END IF
                iaddit = iaddit + 1
                IF (i == j) THEN
                   CYCLE
                END IF
                DO k=1,3
                   DO l=1,3
                      A(k,l) = A(k,l) + 3.0_prec * masses(j) &
                           * drs_(k,j) * drs_(l,j) * ir5d_(j)
                   END DO
                   A(k,k) = A(k,k) - masses(j) * ir3d_(j)
                END DO
                IF (iaddit == naddit) THEN
                   EXIT
                END IF
             END DO
          END IF
          A = gc * A

          ! Integrable part of the interaction
          DO k=1,3
             DO l=1,3
                B(k,l) = 3.0_prec * ws(k,i) * ws(l,i) * ir5s
             END DO
             B(k,k) = B(k,k) - ir3s
          END DO
          B = gc * B

          ! Relativistic term from the Sun
          IF (relativity) THEN
             ir6s = ir4s / r2s
             DO k=1,3
                DO l=1,3
                   P1(k,l) = (3.0_prec * v2s * ir5s - &
                        16.0_prec * gc * ir6s) * ws(k,i) * ws(l,i) - &
                        12.0_prec * us * ir5s * ws(k+3,i) * ws(l,i) + &
                        4.0_prec * ir3s * ws(k+3,i) * ws(l+3,i)
                END DO
                P1(k,k) = P1(k,k) + 4.0_prec *gc * ir4s - v2s * ir3s
             END DO
             P1 = gc * ic2 * P1

             DO k=1,3
                DO l=1,3
                   P2(k,l) = 2.0_prec * ws(k+3,i) * ws(l,i) - ws(k,i) * ws(l+3,i)
                END DO
                P2(k,k) = P2(k,k) + 2.0_prec * us
             END DO
             P2 = 2.0_prec * gc * ic2 * ir3s * P2
          ELSE
             P1 = 0.0_prec
             P2 = 0.0_prec
          END IF

          ! Partial derivatives of the force function.
          ! Put the parts together.
          pwds(:,:,i) = 0.0_prec
          DO k=1,3
             pwds(k,k+3,i) = 1.0_prec
          END DO
          pwds(4:6,1:3,i) = A + B + P1
          pwds(4:6,4:6,i) = P2

       END IF

    END DO
    IF (ASSOCIATED(asteroid_masses)) THEN
       DEALLOCATE(asteroid_masses)
    END IF
    IF (ALLOCATED(wc)) THEN
       DEALLOCATE(wc, stat=err)
    END IF
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE interact_full_jpl






  !! Description:
  !!   Evaluation of the full Newtonian force function for several
  !!   massless bodies. Positions of the massive bodies are read
  !!   from JPL ephemerides. A relativistic term due to the Sun is included.
  !!   Optional argument triggers evaluation of the partial derivatives
  !!   of the force function wrt Cartesian coordinates.
  !!
  !! References:
  !!   [1] Karttunen, Taivaanmekaniikka
  !!
  !! Usage:
  !!   CALL interact_full_jpl(ws, mjd_tdt, wds, error, pwds)
  !!
  !! Interaction.
  !!
  !!  ws       planetocentric, ecliptical (are not they equatorial??), Cartesian coordinates
  !!                 for the massless bodies
  !!  mjd_tdt  modified Julian date (for ephemerides)
  !!  wds      evaluated force function
  !!  error    true, if reading from ephemerides fails
  !!  pwds     evaluated partial derivatives of the force function
  !!
  SUBROUTINE interact_full_jpl_center(ws, mjd_tdt, wds, error, pwds)

    REAL(prec), DIMENSION(:,:), INTENT(in)              :: ws
    REAL(prec), INTENT(in)                              :: mjd_tdt
    REAL(prec), DIMENSION(:,:), INTENT(out)             :: wds
    LOGICAL, INTENT(inout)                              :: error
    REAL(prec), DIMENSION(:,:,:), OPTIONAL, INTENT(out) :: pwds

    ! Number of massive bodies.
    INTEGER, PARAMETER :: N = 11
    ! Number of massless bodies.
    INTEGER            :: NS

    ! Coordinates for the massive bodies.
    REAL(prec), DIMENSION(:,:), POINTER :: wc_sun => NULL()
    REAL(prec), DIMENSION(:,:), ALLOCATABLE :: wc
    !REAL(prec), DIMENSION(10,6) :: wc

    ! Planetary masses.
    REAL(prec), DIMENSION(N) :: m

    ! Various distances.
    REAL(prec)                 :: r2s, ir3s, ir5s
    REAL(prec), DIMENSION(N)   :: r2c, ir3c
    REAL(prec), DIMENSION(3,N) :: drs
    REAL(prec), DIMENSION(N)   :: r2d, ir3d, ir5d
    REAL(prec)                 :: ir4s, v2s, us, ir6s

    ! Utility variables.
    REAL(prec), DIMENSION(3,3) :: A, B, P1, P2
    INTEGER :: i, j, k, l, err


    IF (central_body /= 11 .AND. relativity) THEN
       error = .TRUE.
       ! Relativity term can currently only be used in heliocentric system.
       RETURN
    END IF

    ! Get heliocentric positions of massive bodies (-10 = 9 planets + Moon).
    wc_sun => JPL_ephemeris(mjd_tdt, -10, 11, error)
    IF (error) THEN
       DEALLOCATE(wc_sun, stat=err)
       RETURN
    END IF

    ALLOCATE(wc(SIZE(wc_sun,dim=1)+1,SIZE(wc_sun,dim=2)),stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       DEALLOCATE(wc_sun, wc, stat=err)
       RETURN
    END IF

    ! Change of origin
    IF (central_body /= 11) THEN
       ! Sun
       wc(N,1:3) = -1.0_prec * wc_sun(central_body, 1:3)
       ! Other massive bodies
       DO i = 1, N-1
          wc(i,1:3) = wc_sun(i,1:3) - wc_sun(central_body, 1:3)
       END DO
    ELSE
       wc(1:N-1,1:3) = wc_sun(1:N-1,1:3)
    END IF

    ! Planetary masses + Sun.
    m(1:N) = planetary_masses(1:N)

    ! Useful quantities.
    DO i = 1, N
       r2c(i)  = DOT_PRODUCT(wc(i,1:3), wc(i,1:3))
       ir3c(i) = 1.0_prec / (r2c(i) * SQRT(r2c(i)))
    END DO

    ! Number of massless bodies.
    NS = SIZE(ws,dim=2)

    ! Loop over massless bodies.
    DO i = 1, NS

       r2s  = DOT_PRODUCT(ws(1:3,i), ws(1:3,i)) ! ws(6,NS)
       ir3s = 1.0_prec / (r2s * SQRT(r2s))
       DO j = 1, N
          drs(1:3,j) = wc(j,1:3) - ws(1:3,i)
          r2d(j)     = DOT_PRODUCT(drs(1:3,j), drs(1:3,j))
          ir3d(j)    = 1.0_prec / (r2d(j) * SQRT(r2d(j)))
       END DO

       ! Initialize force function.
       wds(1:3,i) = ws(4:6,i)
       wds(4:6,i) = 0.0_prec

       ! Non-integrable part of the interaction.
       DO j = 1, N
          IF (j == central_body) CYCLE
          wds(4:6,i) = wds(4:6,i) + &
               m(j)* (drs(1:3,j) * ir3d(j) - wc(j,1:3) * ir3c(j))
          !if (j == 3) print*,m(j)* (drs(1:3,j) * ir3d(j) - wc(j,1:3) * ir3c(j))
       END DO
       wds(4:6,i) = gc * wds(4:6,i)

       ! Integrable part of the interaction.
       !wds(4:6,i) = wds(4:6,i) - gc * ws(1:3,i) * ir3s
       wds(4:6,i) = wds(4:6,i) - planetary_mu(central_body) * ws(1:3,i) * ir3s

       ! Relativistic term from the Sun (isotropic coordinates).
       ! CHECK THIS FOR NON-HELIOCENTRIC FRAME!
       ! (Sitarski (1983) AcA 33)
       ir4s = 1.0_prec / (r2s ** 2)
       v2s  = DOT_PRODUCT(ws(4:6,i), ws(4:6,i))
       us   = DOT_PRODUCT(ws(1:3,i), ws(4:6,i))
       ! Optionally, no relativistic term (see global module parameter)
       IF (relativity) THEN
          wds(4:6,i) = wds(4:6,i) &
               + gc * ((4.0_prec * gc * ir4s - v2s * ir3s) * ws(1:3,i) &
               + 4.0_prec * us * ir3s * ws(4:6,i)) * ic2
       END IF

       ! Optional part.
       IF (PRESENT(pwds)) THEN

          ! Some useful quantities.
          ir5s = ir3s / r2s
          ir5d = ir3d / r2d
          ir6s = ir4s / r2s

          ! Non-integrable part of the interaction
          A = 0.0_prec
          DO j = 1, N
             IF (j == central_body) CYCLE
             DO k = 1, 3
                DO l = 1, 3
                   A(k,l) = A(k,l) + 3.0_prec * m(j) &
                        * drs(k,j) * drs(l,j) * ir5d(j)
                END DO
                A(k,k) = A(k,k) - m(j) * ir3d(j)
             END DO
          END DO
          A = gc * A

          ! Integrable part of the interaction
          DO k = 1, 3
             DO l = 1, 3
                B(k,l) = 3.0_prec * ws(k,i) * ws(l,i) * ir5s
             END DO
             B(k,k) = B(k,k) - ir3s
          END DO
          B = gc * B

          ! Relativistic term from the Sun
          IF (relativity) THEN
             DO k = 1, 3
                DO l = 1, 3
                   P1(k,l) = (3.0_prec * v2s * ir5s - &
                        16.0_prec * gc * ir6s) * ws(k,i) * ws(l,i) - &
                        12.0_prec * us * ir5s * ws(k+3,i) * ws(l,i) + &
                        4.0_prec * ir3s * ws(k+3,i) * ws(l+3,i)
                END DO
                P1(k,k) = P1(k,k) + 4.0_prec *gc * ir4s - v2s * ir3s
             END DO
             P1 = gc * ic2 * P1

             DO k = 1, 3
                DO l = 1, 3
                   P2(k,l) = 2.0_prec * ws(k+3,i) * ws(l,i) - ws(k,i) * ws(l+3,i)
                END DO
                P2(k,k) = P2(k,k) + 2.0_prec * us
             END DO
             P2 = 2.0_prec * gc * ic2 * ir3s * P2
          ELSE
             P1 = 0.0_prec
             P2 = 0.0_prec
          END IF

          ! Partial derivatives of the force function.
          ! Put the parts together.
          pwds(:,:,i) = 0.0_prec
          DO k = 1, 3
             pwds(k,k+3,i) = 1.0_prec
          END DO
          pwds(4:6,1:3,i) = A + B + P1
          pwds(4:6,4:6,i) = P2

       END IF

    END DO

    DEALLOCATE(wc, wc_sun, stat=err)
    IF (err /= 0) THEN
       error = .TRUE.
       RETURN
    END IF

  END SUBROUTINE interact_full_jpl_center



  SUBROUTINE set_relativity(rel)

    IMPLICIT NONE
    LOGICAL, INTENT(in) :: rel

    relativity = rel

  END SUBROUTINE set_relativity




!!!!!!!!!
  !
  ! Subroutines and functions that implement the universal Kepler
  ! solver by Wisdom and Hernandez (2015, MNRAS 453,
  ! 3015-3023). Translation from original C code to Fortran 90 by MG.

  SUBROUTINE solve_universal_newton(r0, beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec) :: x
    REAL(prec) :: g1, g2, g3, arg
    REAL(prec) :: s2, c2, xnew
    INTEGER  :: count
    REAL(prec) :: cc

    xnew = XX

    DO count=0,10
       x = xnew
       arg = b*x/2.0_prec
       s2 = SIN(arg)
       c2 = COS(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/beta
       g3 = (x - g1)/beta
       cc = eta*g1 + zeta*g2
       xnew = (h + (x*cc - (eta*g2 + zeta*g3)))/(r0 + cc)
       IF (ABS((x-xnew)/xnew) < 1.0e-8_prec) EXIT
    END DO
    IF (count > 10) THEN
       error = .TRUE.
       RETURN
    END IF

    ! compute the output
    x = xnew
    arg = b*x/2.0_prec
    s2 = SIN(arg)
    c2 = COS(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_newton




  SUBROUTINE solve_universal_laguerre(r0, beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec), PARAMETER :: c5=5.0_prec, c16 = 16.0_prec, c20 = 20.0_prec

    REAL(prec) :: x
    REAL(prec) :: g1, g2, g3
    REAL(prec) :: arg, s2, c2, xnew, dx
    REAL(prec) :: f, fp, fpp, g0
    INTEGER  :: count
    REAL(prec) :: cc

    xnew = XX

    DO count=0,10
       x = xnew
       arg = b*x/2.0_prec
       s2 = SIN(arg)
       c2 = COS(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/beta
       g3 = (x - g1)/beta
       f = r0*x + eta*g2 + zeta*g3 - h
       fp = r0 + eta*g1 + zeta*g2
       g0 = 1.0_prec - beta*g2
       fpp = eta*g0 + zeta*g1
       dx = -c5*f/(fp + SQRT(ABS(c16*fp*fp - c20*f*fpp)))
       xnew = x + dx
       IF (ABS(dx/xnew) < 2.0e-7_prec) EXIT
    END DO
    IF (count > 10) THEN
       error = .TRUE.
       RETURN
    END IF

    ! refine with a last newton
    x = xnew
    arg = b*x/2.0_prec
    s2 = SIN(arg)
    c2 = COS(arg)
    g1 = 2.0_prec*s2*c2/b
    g2 = 2.0_prec*s2*s2/beta
    g3 = (x - g1)/beta
    cc = eta*g1 + zeta*g2
    xnew = (h + (x*cc - (eta*g2 + zeta*g3)))/(r0 + cc)

    x = xnew
    arg = b*x/2.0_prec
    s2 = SIN(arg)
    c2 = COS(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_laguerre




  SUBROUTINE solve_universal_bisection(r0, beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE
    REAL(prec) :: r0
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec) :: x
    REAL(prec) :: g1, g2, g3
    REAL(prec) :: arg, s2, c2
    REAL(prec) :: f
    REAL(prec) :: X_min, X_max, X_per_period, invperiod
    INTEGER  :: count
    REAL(prec) :: xnew

    xnew = XX

    ! bisection limits due to Rein et al.
    invperiod = b*beta/(two_pi*planetary_mu(central_body))
    X_per_period = two_pi/b
    X_min = X_per_period * FLOOR(h*invperiod)
    X_max = X_min + X_per_period
    xnew = (X_max + X_min)/2.

    DO count=0,100
       x = xnew
       arg = b*x/2.0_prec
       s2 = SIN(arg)
       c2 = COS(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/beta
       g3 = (x - g1)/beta
       f = r0*x + eta*g2 + zeta*g3 - h
       IF (f >= 0.0_prec) THEN
          X_max = x
       ELSE
          X_min = x
       END IF
       xnew = (X_max + X_min)/2.0_prec
       IF (ABS((x - xnew)/xnew) < 1.e-9_prec) EXIT
    END DO
    IF (count > 100) THEN
       error = .TRUE.
       RETURN
    END IF

    x = xnew
    arg = b*x/2.0_prec
    s2 = SIN(arg)
    c2 = COS(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_bisection




  REAL(prec) FUNCTION usign(x)

    IMPLICIT NONE
    REAL(prec) :: x

    IF (x > 0.0_prec) THEN
       usign = 1.0_prec
    ELSE IF (x < 0.0_prec) THEN
       usign = -1.0_prec
    ELSE
       usign = 0.0_prec
    END IF

  END FUNCTION usign




  REAL(prec) FUNCTION cubic1(a, b, c)

    IMPLICIT NONE

    REAL(prec) :: a
    REAL(prec) :: b
    REAL(prec) :: c

    REAL(prec) :: Q, R
    REAL(prec) :: theta, aa, bb

    Q = (a*a - 3.0_prec*b)/9.0_prec
    R = (2.0_prec*a*a*a - 9.0_prec*a*b + 27.0_prec*c)/54.0_prec

    IF (R*R < Q*Q*Q) THEN

       theta = ACOS(R/SQRT(Q*Q*Q))

       WRITE(*,*) "three cubic roots ", & 
            -2.0*SQRT(Q)*COS(theta/3.0) - a/3.0, &
            -2.0*SQRT(Q)*COS((theta + two_pi)/3.0) - a/3.0, &
            -2.0*SQRT(Q)*COS((theta - two_pi)/3.0) - a/3.0

    ELSE

       aa = -usign(R)*(ABS(R) + SQRT(R*R - Q*Q*Q))**(1.0_prec/3.0_prec)
       IF (aa == 0.0_prec) THEN
          bb = 0.0_prec
       ELSE
          bb = Q/aa
       END IF
       cubic1 = (aa + bb) - a/3.0_prec

    END IF

  END FUNCTION cubic1




  SUBROUTINE solve_universal_parabolic(r0, beta, b, eta, zeta, h, XX, SS2, CC2)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2

    REAL(prec) :: x
    REAL(prec) :: s2, c2

    b = 0.0_prec

    s2 = 0.0_prec
    c2 = 1.0_prec
    !/*
    !  g1 = x
    !  g2 = x*x/2.0
    !  g3 = x*x*x/6.0
    !  g = eta*g1 + zeta*g2
    ! */
    !/*   f = r0*x + eta*g2 + zeta*g3 - h */
    !/*   this is just a cubic equation */
    x = cubic1(3.0_prec*eta/zeta, 6.0_prec*r0/zeta, -6.0_prec*h/zeta)

    !s2 = 0.0
    !c2 = 1.0
    !/* g1 = 2.0*s2*c2/b */
    !/* g2 = 2.0*s2*s2/beta */

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_parabolic




  SUBROUTINE solve_universal_hyperb_newton(r0, minus_beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: minus_beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec) :: x
    REAL(prec) :: g1, g2, g3
    REAL(prec) :: arg, s2, c2, xnew
    INTEGER  :: count
    REAL(prec) :: g

    xnew = XX

    DO count=0,10
       x = xnew
       arg = b*x/2.0_prec
       IF (ABS(arg) > 200.0_prec) THEN
          error = .TRUE.
          RETURN
       END IF
       s2 = SINH(arg)
       c2 = COSH(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/minus_beta
       g3 = -(x - g1)/minus_beta
       g = eta*g1 + zeta*g2
       xnew = (x*g - eta*g2 - zeta*g3 + h)/(r0 + g)
       IF (ABS((x-xnew)/xnew) < 1.0e-9_prec) EXIT
    END DO
    IF (count > 10) THEN
       error = .TRUE.
       RETURN
    END IF

    x = xnew
    arg = b*x/2.0_prec
    s2 = SINH(arg)
    c2 = COSH(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_hyperb_newton




  SUBROUTINE solve_universal_hyperb_laguerre(r0, minus_beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: minus_beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec), PARAMETER :: c5=5.0_prec, c16 = 16.0_prec, c20 = 20.0_prec

    REAL(prec) :: fp, fpp, dx
    REAL(prec) :: den
    REAL(prec) :: x
    REAL(prec) :: g0, g1, g2, g3
    REAL(prec) :: arg, s2, c2, xnew
    INTEGER  :: count
    REAL(prec) :: f, g

    xnew = XX

    DO count=0,20
       x = xnew
       arg = b*x/2.0_prec
       IF (ABS(arg) > 50.0_prec) THEN
          error = .TRUE.
          RETURN
       END IF
       s2 = SINH(arg)
       c2 = COSH(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/minus_beta
       g3 = -(x - g1)/minus_beta
       f = r0*x + eta*g2 + zeta*g3 - h
       fp = r0 + eta*g1 + zeta*g2
       g0 = 1.0_prec + minus_beta*g2
       fpp = eta*g0 + zeta*g1
       den = (fp + SQRT(ABS(c16*fp*fp - c20*f*fpp)))
       IF (den == 0.0) THEN
          error = .TRUE.
          RETURN
       END IF
       dx = -c5*f/den
       xnew = x + dx
       IF (ABS((x-xnew)/xnew) < 1.0e-9_prec) EXIT

    END DO
    IF (count > 20) THEN
       error = .TRUE.
       RETURN
    END IF

    ! refine with a step of Newton
    x = xnew
    arg = b*x/2.0_prec
    IF (ABS(arg) > 200.0_prec) THEN
       error = .TRUE.
       RETURN
    END IF
    s2 = SINH(arg)
    c2 = COSH(arg)
    g1 = 2.0_prec*s2*c2/b
    g2 = 2.0_prec*s2*s2/minus_beta
    g3 = -(x - g1)/minus_beta
    g = eta*g1 + zeta*g2
    xnew = (x*g - eta*g2 - zeta*g3 + h)/(r0 + g)

    x = xnew
    arg = b*x/2.0_prec
    s2 = SINH(arg)
    c2 = COSH(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_hyperb_laguerre




  SUBROUTINE solve_universal_hyperb_bisect(r0, minus_beta, b, eta, zeta, h, XX, SS2, CC2, error)

    IMPLICIT NONE

    REAL(prec) :: r0
    REAL(prec) :: minus_beta
    REAL(prec) :: b
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: h
    REAL(prec) :: XX
    REAL(prec) :: SS2
    REAL(prec) :: CC2
    LOGICAL, INTENT(inout) :: error

    REAL(prec) :: x
    REAL(prec) :: g1, g2, g3
    REAL(prec) :: arg, s2, c2, xnew
    INTEGER  :: count
    REAL(prec) :: X_min, X_max
    REAL(prec) :: f
    REAL(prec) :: err
    REAL(prec) :: fmin, fmax

    xnew = XX
    X_min = 0.5_prec*xnew
    X_max = 10.0_prec*xnew

    x = X_min
    arg = b*x/2.0_prec
    IF (ABS(arg) > 200.0_prec) THEN
       error = .TRUE.
       RETURN
    END IF
    s2 = SINH(arg)
    c2 = COSH(arg)
    g1 = 2.0_prec*s2*c2/b
    g2 = 2.0_prec*s2*s2/minus_beta
    g3 = -(x - g1)/minus_beta
    fmin = r0*x + eta*g2 + zeta*g3 - h

    x = X_max
    arg = b*x/2.0_prec
    IF (ABS(arg) > 200.0) THEN
       x = 200.0_prec/(b/2.0_prec)
       arg = 200.0_prec
    END IF
    s2 = SINH(arg)
    c2 = COSH(arg)
    g1 = 2.0_prec*s2*c2/b
    g2 = 2.0_prec*s2*s2/minus_beta
    g3 = -(x - g1)/minus_beta
    fmax = r0*x + eta*g2 + zeta*g3 - h
    IF (fmin*fmax > 0.0_prec) THEN
       error = .TRUE.
       RETURN
    END IF

    DO count=0,100
       x = xnew
       arg = b*x/2.0_prec
       IF (ABS(arg) > 200.0_prec) THEN
          error = .TRUE.
          RETURN
       END IF
       s2 = SINH(arg)
       c2 = COSH(arg)
       g1 = 2.0_prec*s2*c2/b
       g2 = 2.0_prec*s2*s2/minus_beta
       g3 = -(x - g1)/minus_beta
       f = r0*x + eta*g2 + zeta*g3 - h
       IF (f >= 0.0_prec) THEN
          X_max = x
       ELSE
          X_min = x
       END IF
       xnew = (X_max + X_min)/2.0_prec
       IF (ABS((x-xnew)/xnew) < 1.0e-10_prec) EXIT
    END DO
    IF (count > 100) THEN
       error = .TRUE.
       RETURN
    END IF

    x = xnew
    arg = b*x/2.0_prec
    s2 = SINH(arg)
    c2 = COSH(arg)

    XX = x
    SS2 = s2
    CC2 = c2

  END SUBROUTINE solve_universal_hyperb_bisect




  SUBROUTINE kepler_step(ncenter, dt, s0, s, error)

    IMPLICIT NONE
    INTEGER, INTENT(in) :: ncenter
    REAL(prec), INTENT(in) :: dt
    REAL(prec), DIMENSION(6), INTENT(in) :: s0
    REAL(prec), DIMENSION(6), INTENT(out) :: s
    LOGICAL, INTENT(inout) :: error
    REAL(prec) :: r0, v2, eta, beta, zeta, b

    central_body = ncenter

    r0 = SQRT(dot_PRODUCT(s0(1:3),s0(1:3)))
    v2 = dot_PRODUCT(s0(4:6),s0(4:6))
    eta = dot_PRODUCT(s0(1:3),s0(4:6))
    beta = 2.0_prec*planetary_mu(central_body)/r0 - v2
    zeta = planetary_mu(central_body) - beta*r0
    b = SQRT(ABS(beta))

    CALL kepler_step_depth(dt, beta, b, s0, s, 0, r0, v2, eta, zeta, error)
    IF (error) THEN
       WRITE(0,"(A)") "kepler_step: Failed 2-body propagation using universal Kepler solver."
       RETURN
    END IF

  END SUBROUTINE kepler_step




  RECURSIVE SUBROUTINE kepler_step_depth(dt, beta, b, s0, s, depth, r0, v2, eta, zeta, error)

    IMPLICIT NONE
    REAL(prec) :: dt
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec), DIMENSION(6) :: s0
    REAL(prec), DIMENSION(6) :: s
    INTEGER :: depth 
    REAL(prec) :: r0
    REAL(prec) :: v2
    REAL(prec) :: eta
    REAL(prec) :: zeta
    LOGICAL, INTENT(inout) :: error

    REAL(prec), DIMENSION(6) :: ss

    IF (depth > 30) THEN
       error = .TRUE.
       WRITE(0,"(A)") "kepler_step_depth: kepler depth exceeded."
       RETURN
    END IF

    CALL kepler_step_internal(dt, beta, b, s0, s, r0, v2, eta, zeta, error)

    IF (error) THEN
       error = .FALSE.

       CALL kepler_step_depth(dt/4.0, beta, b, s0, ss, depth+1, r0, v2, eta, zeta, error)

       r0 = SQRT(dot_PRODUCT(ss(1:3),ss(1:3)))
       v2 = dot_PRODUCT(ss(4:6),ss(4:6))
       eta = dot_PRODUCT(ss(1:3),ss(4:6))
       zeta = planetary_mu(central_body) - beta*r0

       CALL kepler_step_depth(dt/4.0, beta, b, ss, s, depth+1, r0, v2, eta, zeta, error)

       r0 = SQRT(dot_PRODUCT(s(1:3),s(1:3)))
       v2 = dot_PRODUCT(s(4:6),s(4:6))
       eta = dot_PRODUCT(s(1:3),s(4:6))
       zeta = planetary_mu(central_body) - beta*r0

       CALL kepler_step_depth(dt/4.0, beta, b, s, ss, depth+1, r0, v2, eta, zeta, error)

       r0 = SQRT(dot_PRODUCT(ss(1:3),ss(1:3)))
       v2 = dot_PRODUCT(ss(4:6),ss(4:6))
       eta = dot_PRODUCT(ss(1:3),ss(4:6))
       zeta = planetary_mu(central_body) - beta*r0

       CALL kepler_step_depth(dt/4.0, beta, b, ss, s, depth+1, r0, v2, eta, zeta, error)

    END IF

  END SUBROUTINE kepler_step_depth




  REAL(prec) FUNCTION new_guess(r0, eta, zeta, dt)

    IMPLICIT NONE
    REAL(prec) :: r0
    REAL(prec) :: eta
    REAL(prec) :: zeta
    REAL(prec) :: dt
    REAL(prec) :: reta, disc

    IF (zeta /= 0.0_prec) THEN
       new_guess = cubic1(3.0_prec*eta/zeta, 6.0_prec*r0/zeta, -6.0_prec*dt/zeta)
    ELSE IF (eta /= 0.0_prec) THEN
       reta = r0/eta
       disc = reta*reta + 8.0_prec*dt/eta
       IF (disc >= 0.0_prec) THEN
          new_guess = -reta + SQRT(disc)
       ELSE
          new_guess = dt/r0
       END IF
    ELSE 
       new_guess = dt/r0
    END IF

  END FUNCTION new_guess




  SUBROUTINE kepler_step_internal(dt, beta, b, s0, s, r0, v2, eta, zeta, error)

    IMPLICIT NONE
    REAL(prec) :: dt
    REAL(prec) :: beta
    REAL(prec) :: b
    REAL(prec), DIMENSION(6) :: s0
    REAL(prec), DIMENSION(6) :: s
    REAL(prec) :: r0
    REAL(prec) :: v2
    REAL(prec) :: eta
    REAL(prec) :: zeta
    LOGICAL, INTENT(inout) :: error

    REAL(prec) :: r
    REAL(prec) :: c2, s2
    REAL(prec) :: G1, G2
    REAL(prec) :: a, x, x0
    REAL(prec) :: c, ca, bsa
    REAL(prec) :: ff, fp
    REAL(prec) :: g, fdot, fhat, gdothat

    IF (beta < 0.0_prec) THEN

       x0 = new_guess(r0, eta, zeta, dt)

       x = x0
       CALL solve_universal_hyperb_newton(r0, -beta, b, eta, zeta, dt, x, s2, c2, error)

       IF (error) THEN
          error = .FALSE.
          x = x0
          CALL solve_universal_hyperb_laguerre(r0, -beta, b, eta, zeta, dt, x, s2, c2, error)
       END IF


       !if(flag == FAILURE) {
       !  x = x0
       !  flag = solve_universal_hyperb_bisect(r0, -beta, b, eta, zeta, dt, x, s2, c2, error)
       !}
       IF (error) THEN
          RETURN
       END IF

       a = planetary_mu(central_body)/(-beta)
       G1 = 2.0_prec*s2*c2/b
       c = 2.0_prec*s2*s2
       G2 = c/(-beta)
       ca = c*a
       r = r0 + eta*G1 + zeta*G2
       bsa = (a/r)*(b/r0)*2.0_prec*s2*c2

    ELSE IF (beta > 0.0_prec) THEN

       x0 = dt/r0
       ff = zeta*x0*x0*x0 + 3.0_prec*eta*x0*x0
       fp = 3.0_prec*zeta*x0*x0 + 6.0_prec*eta*x0 + 6.0_prec*r0
       x0 = x0 - ff/fp

       x = x0
       CALL solve_universal_newton(r0, beta, b, eta, zeta, dt, x, s2, c2, error)
       IF (error) THEN
          error = .FALSE.
          x = x0
          CALL solve_universal_laguerre(r0, beta, b, eta, zeta, dt, x, s2, c2, error)
       END IF
       !if(flag == FAILURE) {
       !  x = x0
       !  flag = solve_universal_bisection(r0, beta, b, eta, zeta, dt, &x, &s2, &c2)
       !}

       IF (error) THEN
          RETURN
       END IF

       a = planetary_mu(central_body)/beta
       G1 = 2.0_prec*s2*c2/b
       c = 2.0_prec*s2*s2
       G2 = c/beta
       ca = c*a
       r = r0 + eta*G1 + zeta*G2
       bsa = (a/r)*(b/r0)*2.0_prec*s2*c2

    ELSE

       x = dt/r0

       CALL solve_universal_parabolic(r0, beta, b, eta, zeta, dt, x, s2, c2)
       IF (error) THEN
          RETURN
       END IF

       G1 = x
       G2 = x*x/2.0_prec
       ca = planetary_mu(central_body)*G2
       r = r0 + eta*G1 + zeta*G2
       bsa = planetary_mu(central_body)*x/(r*r0)

    END IF


    ! f = 1.0 - (ca/r0)
    fhat = -(ca/r0)
    g = eta*G2 + r0*G1
    fdot = -bsa
    ! gdot = 1.0 - (ca/r)
    gdothat = -(ca/r)

    s(1:3) = s0(1:3) + (fhat*s0(1:3) + g*s0(4:6))
    s(4:6) = s0(4:6) + (fdot*s0(1:3) + gdothat*s0(4:6))

  END SUBROUTINE kepler_step_internal

  !
  ! End implementation of the universal Kepler solver by Wisdom and Hernandez.
  !
!!!!!!!!!!!!!!!!!!!!

END MODULE integrators
